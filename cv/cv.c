/*
 * cv - fast schema validator for Tarantool
 *
 * TODO (OpenAPI compatibility, not yet implemented):
 *  - format: string formats (int32, int64, float, double,
 *            date-time, tarantool datetime)
 *  - additionalProperties: schema for extra keys
 *  - anyOf, allOf
 */

#include <tarantool/module.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* =========================================================
 * Type codes
 * ========================================================= */

enum cv_type {
	CV_TYPE_ANY      = 0,
	CV_TYPE_BOOLEAN,
	CV_TYPE_STRING,
	CV_TYPE_NUMBER,
	CV_TYPE_INTEGER,
	CV_TYPE_UNSIGNED,
	CV_TYPE_NULL,
	CV_TYPE_NIL,
	CV_TYPE_UUID,
	CV_TYPE_TUPLE,
	CV_TYPE_FUNCTION,
	CV_TYPE_MAP,
	CV_TYPE_ARRAY,
	CV_TYPE_ONEOF,
	CV_TYPE__MAX
};

static const char *cv_type_names[] = {
	"any",
	"boolean",
	"string",
	"number",
	"integer",
	"unsigned",
	"null",
	"nil",
	"uuid",
	"tuple",
	"function",
	"map",
	"array",
	"oneof",
};

/* =========================================================
 * Forward declaration (cv_node is recursive)
 * ========================================================= */

struct cv_node;

/* =========================================================
 * cv_enum
 * ========================================================= */

struct cv_enum {
	int  *refs;
	int   count;
};

/* =========================================================
 * cv_key: a table key - either integer or string.
 * ========================================================= */

struct cv_key {
	bool is_int;
	union {
		int   ival; /* valid when is_int */
		char *sval; /* malloc'd; valid when !is_int */
	};
};

/* =========================================================
 * cv_rename_entry: one rename pair (from -> to).
 *
 * Sort order (applied at compile time):
 *   1. integer from, ascending
 *   2. string  from, lexicographic
 * ========================================================= */

struct cv_rename_entry {
	struct cv_key from;
	struct cv_key to;
};

struct cv_rename {
	struct cv_rename_entry *entries;
	int                     count;
};

/* =========================================================
 * cv_key helpers
 * ========================================================= */

static void
cv_key_free(struct cv_key *k)
{
	if (!k->is_int && k->sval != NULL) {
		free(k->sval);
		k->sval = NULL;
	}
}

/*
 * Compare two cv_key values.
 * Returns true if equal.
 */
static bool
cv_key_eq(const struct cv_key *a,
          const struct cv_key *b)
{
	if (a->is_int != b->is_int)
		return false;
	if (a->is_int)
		return a->ival == b->ival;
	return strcmp(a->sval, b->sval) == 0;
}

static bool
cv_key_eq_str(const struct cv_key *k,
              const char *s)
{
	return !k->is_int && strcmp(k->sval, s) == 0;
}

static bool
cv_key_eq_int(const struct cv_key *k, int i)
{
	return k->is_int && k->ival == i;
}

/* =========================================================
 * cv_property: one named property of a map
 * ========================================================= */

struct cv_property {
	struct cv_key   key;
	struct cv_node *node;
	struct cv_key  *aliases;  /* malloc'd array of aliases */
	int             naliases;
};

/* =========================================================
 * cv_node
 * ========================================================= */

struct cv_node {
	enum cv_type type;
	bool         optional;
	bool         nullable;

	int  default_ref;     /* LUA_NOREF if absent */
	int  name_ref;        /* LUA_NOREF if absent */
	int  constraint_ref;  /* LUA_NOREF if absent */
	int  transform_ref;   /* LUA_NOREF if absent */

	union {
		struct {
			bool           has_min_length;
			bool           has_max_length;
			size_t         min_length;
			size_t         max_length;
			int            pattern_ref;
			struct cv_enum enums;
		} string;

		struct {
			int            min_ref;
			int            max_ref;
			int            gt_ref;
			int            lt_ref;
			struct cv_enum enums;
		} number;

		struct {
			/*
			 * properties: named fields.
			 * items: wildcard schema for all
			 *        keys (mutually exclusive
			 *        with properties).
			 * skip_unexpected_check,
			 * return_unexpected - flags.
			 */
			struct cv_property *props;
			int                 nprops;
			struct cv_node     *items; /* or NULL */
			bool                skip_unexpected;
			bool                return_unexpected;
			struct cv_rename    rename;
		} map;

		struct {
			/* items schema (may be NULL = any) */
			struct cv_node *items;
			bool            has_min_items;
			bool            has_max_items;
			size_t          min_items;
			size_t          max_items;
		} array;

		struct {
			struct cv_node **variants;
			int              nvariants;
			/* ref to original Lua schema table
			 * for oneof_schema in error details */
			int              schema_ref;
		} oneof;
	} as;
};

/* =========================================================
 * Static OOM error
 * ========================================================= */

static int cv_oom_error_ref = LUA_NOREF;

/* =========================================================
 * Runtime type handles (set by cv._init)
 * ========================================================= */

/* CTypeIDs for int64_t / uint64_t — set at _init time */
static uint32_t cv_ctid_int64  = 0;
static uint32_t cv_ctid_uint64 = 0;

/* Lua refs for type checkers / helpers */
static int cv_ref_uuid_is     = LUA_NOREF;
static int cv_ref_tuple_is    = LUA_NOREF;
static int cv_ref_ffi_typestr = LUA_NOREF;
static int cv_ref_box_null    = LUA_NOREF;
static int cv_ref_deepcopy    = LUA_NOREF;

/*
 * Helper: is cdata at idx an int64_t?
 */
static bool
cv_is_int64(lua_State *L, int idx)
{
	if (!luaL_iscdata(L, idx))
		return false;
	uint32_t ctid = 0;
	luaL_checkcdata(L, idx, &ctid);
	return ctid == cv_ctid_int64;
}

/*
 * Helper: is cdata at idx a uint64_t?
 */
static bool
cv_is_uint64(lua_State *L, int idx)
{
	if (!luaL_iscdata(L, idx))
		return false;
	uint32_t ctid = 0;
	luaL_checkcdata(L, idx, &ctid);
	return ctid == cv_ctid_uint64;
}

/*
 * Helper: push cdata type string onto stack.
 * Uses ffi_typestr Lua function if available,
 * otherwise pushes "cdata".
 */
static void
cv_push_cdata_typestr(lua_State *L, int idx)
{
	if (cv_ref_ffi_typestr != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    cv_ref_ffi_typestr);
		lua_pushvalue(L, idx);
		if (lua_pcall(L, 1, 1, 0) == 0)
			return; /* result on stack */
		lua_pop(L, 1); /* pop error */
	}
	lua_pushstring(L, "cdata");
}

/* =========================================================
 * Error helpers
 * ========================================================= */

static void
push_schema_error(lua_State *L, const char *path,
                  const char *message,
                  const char *got,
                  const char *expected)
{
	lua_newtable(L);

	lua_pushstring(L, path);
	lua_setfield(L, -2, "path");

	lua_pushstring(L, "SCHEMA_ERROR");
	lua_setfield(L, -2, "type");

	lua_pushstring(L, message);
	lua_setfield(L, -2, "message");

	if (got != NULL || expected != NULL) {
		lua_newtable(L);
		if (got != NULL) {
			lua_pushstring(L, got);
			lua_setfield(L, -2, "got");
		}
		if (expected != NULL) {
			lua_pushstring(L, expected);
			lua_setfield(L, -2, "expected");
		}
		lua_setfield(L, -2, "details");
	}
}

static void
append_error(lua_State *L, int errors_idx)
{
	int eidx = (int)lua_objlen(L, errors_idx) + 1;
	lua_rawseti(L, errors_idx, eidx);
}

/* =========================================================
 * cv_enum helpers
 * ========================================================= */

static void
cv_enum_free(lua_State *L, struct cv_enum *e)
{
	if (e->refs == NULL)
		return;
	for (int i = 0; i < e->count; i++) {
		if (e->refs[i] != LUA_NOREF)
			luaL_unref(L, LUA_REGISTRYINDEX,
			           e->refs[i]);
	}
	free(e->refs);
	e->refs  = NULL;
	e->count = 0;
}

/* =========================================================
 * cv_rename helpers
 * ========================================================= */

static void
cv_rename_free(struct cv_rename *r)
{
	if (r->entries == NULL)
		return;
	for (int i = 0; i < r->count; i++) {
		if (!r->entries[i].from.is_int)
			free(r->entries[i].from.sval);
		if (!r->entries[i].to.is_int)
			free(r->entries[i].to.sval);
	}
	free(r->entries);
	r->entries = NULL;
	r->count   = 0;
}

/*
 * Comparator for qsort: integers first (ascending),
 * then strings (lexicographic).
 */
static int
cv_rename_cmp(const void *a, const void *b)
{
	const struct cv_rename_entry *ea = a;
	const struct cv_rename_entry *eb = b;

	if (ea->from.is_int && eb->from.is_int)
		return ea->from.ival - eb->from.ival;
	if (ea->from.is_int)
		return -1; /* ints before strings */
	if (eb->from.is_int)
		return 1;
	return strcmp(ea->from.sval, eb->from.sval);
}

/* =========================================================
 * cv_node forward declarations
 * ========================================================= */

static struct cv_node *cv_node_alloc(void);
static void cv_node_free(lua_State *L, struct cv_node *n);

/* =========================================================
 * cv_property helpers
 * ========================================================= */

static void
cv_props_free(lua_State *L,
              struct cv_property *props, int nprops)
{
	if (props == NULL)
		return;
	for (int i = 0; i < nprops; i++) {
		cv_key_free(&props[i].key);
		cv_node_free(L, props[i].node);
		for (int j = 0; j < props[i].naliases; j++)
			cv_key_free(&props[i].aliases[j]);
		free(props[i].aliases);
	}
	free(props);
}

/* =========================================================
 * cv_node lifecycle
 * ========================================================= */

static struct cv_node *
cv_node_alloc(void)
{
	struct cv_node *n = calloc(1, sizeof(*n));
	if (n == NULL)
		return NULL;
	n->default_ref    = LUA_NOREF;
	n->name_ref       = LUA_NOREF;
	n->constraint_ref = LUA_NOREF;
	n->transform_ref  = LUA_NOREF;
	/*
	 * Union fields overlap in memory.
	 * We must initialise every ref field
	 * from every union branch explicitly,
	 * because LUA_NOREF == -2, not 0.
	 * We do it by zeroing then patching the
	 * largest branch (map has the most refs).
	 */
	return n;
}

/*
 * Initialise type-specific ref fields after
 * n->type is set. Must be called right after
 * cv_node_alloc() + n->type = ...
 */
static void
cv_node_init_refs(struct cv_node *n)
{
	switch (n->type) {
	case CV_TYPE_STRING:
		n->as.string.pattern_ref = LUA_NOREF;
		break;
	case CV_TYPE_NUMBER:
	case CV_TYPE_INTEGER:
	case CV_TYPE_UNSIGNED:
		n->as.number.min_ref = LUA_NOREF;
		n->as.number.max_ref = LUA_NOREF;
		n->as.number.gt_ref  = LUA_NOREF;
		n->as.number.lt_ref  = LUA_NOREF;
		break;
	case CV_TYPE_ONEOF:
		n->as.oneof.schema_ref = LUA_NOREF;
		break;
	default:
		break;
	}
}

static void
cv_node_free(lua_State *L, struct cv_node *n)
{
	if (n == NULL)
		return;

#define UNREF(ref) \
	if ((ref) != LUA_NOREF) { \
		luaL_unref(L, LUA_REGISTRYINDEX, (ref)); \
		(ref) = LUA_NOREF; \
	}

	UNREF(n->default_ref);
	UNREF(n->name_ref);
	UNREF(n->constraint_ref);
	UNREF(n->transform_ref);

	switch (n->type) {
	case CV_TYPE_STRING:
		UNREF(n->as.string.pattern_ref);
		cv_enum_free(L, &n->as.string.enums);
		break;
	case CV_TYPE_NUMBER:
	case CV_TYPE_INTEGER:
	case CV_TYPE_UNSIGNED:
		UNREF(n->as.number.min_ref);
		UNREF(n->as.number.max_ref);
		UNREF(n->as.number.gt_ref);
		UNREF(n->as.number.lt_ref);
		cv_enum_free(L, &n->as.number.enums);
		break;
	case CV_TYPE_MAP:
		cv_props_free(L, n->as.map.props,
		              n->as.map.nprops);
		cv_node_free(L, n->as.map.items);
		cv_rename_free(&n->as.map.rename);
		break;
	case CV_TYPE_ARRAY:
		cv_node_free(L, n->as.array.items);
		break;
	case CV_TYPE_ONEOF:
		for (int i = 0;
		     i < n->as.oneof.nvariants; i++)
			cv_node_free(L,
			    n->as.oneof.variants[i]);
		free(n->as.oneof.variants);
		UNREF(n->as.oneof.schema_ref);
		break;
	default:
		break;
	}
#undef UNREF

	free(n);
}

/* =========================================================
 * Type name -> cv_type
 * ========================================================= */

static int
cv_type_by_name(const char *name)
{
	if (strcmp(name, "any")      == 0) return CV_TYPE_ANY;
	if (strcmp(name, "boolean")  == 0) return CV_TYPE_BOOLEAN;
	if (strcmp(name, "string")   == 0) return CV_TYPE_STRING;
	if (strcmp(name, "number")   == 0) return CV_TYPE_NUMBER;
	if (strcmp(name, "integer")  == 0) return CV_TYPE_INTEGER;
	if (strcmp(name, "unsigned") == 0) return CV_TYPE_UNSIGNED;
	if (strcmp(name, "null")     == 0) return CV_TYPE_NULL;
	if (strcmp(name, "nil")      == 0) return CV_TYPE_NIL;
	if (strcmp(name, "uuid")     == 0) return CV_TYPE_UUID;
	if (strcmp(name, "tuple")    == 0) return CV_TYPE_TUPLE;
	if (strcmp(name, "function") == 0) return CV_TYPE_FUNCTION;
	/* OpenAPI aliases */
	if (strcmp(name, "object")   == 0) return CV_TYPE_MAP;
	/* composite */
	if (strcmp(name, "map")      == 0) return CV_TYPE_MAP;
	if (strcmp(name, "table")    == 0) return CV_TYPE_MAP;
	if (strcmp(name, "array")    == 0) return CV_TYPE_ARRAY;
	if (strcmp(name, "oneof")    == 0) return CV_TYPE_ONEOF;
	if (strcmp(name, "oneOf")    == 0) return CV_TYPE_ONEOF;
	return -1;
}

#define CV_NODE_MT "cv.schema_node"

/* =========================================================
 * Parse enum list
 * ========================================================= */

static bool
cv_parse_enum(lua_State *L, int tbl_idx,
              struct cv_enum *out,
              enum cv_type ntype,
              const char *path, int errors_idx)
{
	int n = (int)lua_objlen(L, tbl_idx);
	if (n == 0)
		return true;

	out->refs = calloc(n, sizeof(int));
	if (out->refs == NULL)
		return false;
	for (int i = 0; i < n; i++)
		out->refs[i] = LUA_NOREF;
	out->count = n;

	for (int i = 1; i <= n; i++) {
		lua_rawgeti(L, tbl_idx, i);
		/* accept any value in enum —
		 * type mismatch will be caught at
		 * validation time */
		(void)ntype;
		out->refs[i - 1] =
			luaL_ref(L, LUA_REGISTRYINDEX);
	}
	return true;
}

/* =========================================================
 * cv_compile_node - forward declaration
 * ========================================================= */

static struct cv_node *
cv_compile_node(lua_State *L, int def_idx,
                const char *path, int errors_idx,
                bool *oom);

/* =========================================================
 * Parse map properties table.
 * properties table is at stack index props_idx.
 * ========================================================= */

static bool
cv_parse_properties(lua_State *L, int props_idx,
                    struct cv_node *n,
                    const char *path, int errors_idx,
                    bool *oom)
{
	/* count keys */
	int nprops = 0;
	lua_pushnil(L);
	while (lua_next(L, props_idx) != 0) {
		nprops++;
		lua_pop(L, 1);
	}

	if (nprops == 0)
		return true;

	n->as.map.props = calloc(nprops,
	                         sizeof(struct cv_property));
	if (n->as.map.props == NULL) {
		*oom = true;
		return false;
	}
	n->as.map.nprops = nprops;

	int i = 0;
	lua_pushnil(L);
	while (lua_next(L, props_idx) != 0) {
		/* key at -2, value at -1 */
		struct cv_key pkey;
		char child_path[512];

		if (lua_type(L, -2) == LUA_TSTRING) {
			const char *s = lua_tostring(L, -2);
			pkey.is_int = false;
			pkey.sval   = strdup(s);
			if (pkey.sval == NULL) {
				lua_pop(L, 1);
				*oom = true;
				return false;
			}
			snprintf(child_path,
			         sizeof(child_path),
			         "%s.%s", path, s);
		} else if (lua_type(L, -2) == LUA_TNUMBER) {
			int ival = (int)lua_tointeger(L, -2);
			pkey.is_int = true;
			pkey.ival   = ival;
			snprintf(child_path,
			         sizeof(child_path),
			         "%s[%d]", path, ival);
		} else {
			char ep[256];
			snprintf(ep, sizeof(ep),
			         "%s.properties", path);
			push_schema_error(
				L, ep,
				"Property key must be "
				"string or integer",
				lua_typename(L,
				    lua_type(L, -2)),
				"string or integer"
			);
			append_error(L, errors_idx);
			lua_pop(L, 1);
			continue;
		}

		n->as.map.props[i].key     = pkey;
		n->as.map.props[i].aliases  = NULL;
		n->as.map.props[i].naliases = 0;

		int val_idx = lua_gettop(L);
		struct cv_node *child =
			cv_compile_node(L, val_idx,
			                child_path,
			                errors_idx, oom);
		if (*oom) {
			lua_pop(L, 1);
			return false;
		}
		n->as.map.props[i].node = child;
		i++;
		lua_pop(L, 1); /* pop value */
	}
	/* adjust nprops in case some keys were skipped */
	n->as.map.nprops = i;
	return true;
}

/* =========================================================
 * Compile one schema node
 * ========================================================= */

static struct cv_node *
cv_compile_node(lua_State *L, int def_idx,
                const char *path, int errors_idx,
                bool *oom)
{
	*oom = false;

	const char *type_str = NULL;
	bool nullable_from_type = false;

	if (lua_type(L, def_idx) == LUA_TSTRING) {
		type_str = lua_tostring(L, def_idx);
	} else if (lua_type(L, def_idx) == LUA_TTABLE) {
		/*
		 * Check for {oneOf = {...}} OpenAPI style
		 * before looking at schema[1] or type=.
		 * Only valid when type is absent or 'oneof'.
		 */
		lua_getfield(L, def_idx, "oneOf");
		bool has_oneof = !lua_isnil(L, -1);
		lua_pop(L, 1);

		lua_rawgeti(L, def_idx, 1);
		if (lua_type(L, -1) == LUA_TSTRING) {
			/* {'type', default} shorthand */
			type_str = lua_tostring(L, -1);
			lua_pop(L, 1);
		} else if (lua_type(L, -1) == LUA_TTABLE) {
			/*
			 * OpenAPI 3.1 nullable:
			 * type = {'typename', true/false}
			 * Only when inside a table schema
			 * as the 'type' field, not as schema[1].
			 * Here schema[1] is a table — error.
			 */
			lua_pop(L, 1);
			push_schema_error(
				L, path,
				"schema[1] must be a "
				"type string, not a table",
				NULL, NULL);
			append_error(L, errors_idx);
			return NULL;
		} else {
			lua_pop(L, 1);
			/* look at type= field */
			lua_getfield(L, def_idx, "type");
			if (lua_type(L, -1) == LUA_TSTRING) {
				type_str = lua_tostring(L, -1);
				lua_pop(L, 1);
			} else if (lua_type(L, -1) ==
			           LUA_TTABLE) {
				/*
				 * OpenAPI 3.1: type = {'str', bool}
				 */
				int ttbl = lua_gettop(L);
				int tlen = (int)lua_objlen(L, ttbl);
				if (tlen != 2) {
					char ep[256];
					snprintf(ep, sizeof(ep),
					         "%s.type", path);
					push_schema_error(
						L, ep,
						"type array must have "
						"exactly 2 elements",
						NULL, NULL);
					append_error(L, errors_idx);
					lua_pop(L, 1);
					return NULL;
				}
				lua_rawgeti(L, ttbl, 1);
				if (lua_type(L, -1) !=
				    LUA_TSTRING) {
					char ep[256];
					snprintf(ep, sizeof(ep),
					         "%s.type[1]", path);
					push_schema_error(
						L, ep,
						"type[1] must be "
						"a string",
						lua_typename(L,
						    lua_type(L, -1)),
						"string");
					append_error(L, errors_idx);
					lua_pop(L, 2);
					return NULL;
				}
				type_str = lua_tostring(L, -1);
				lua_pop(L, 1);

				lua_rawgeti(L, ttbl, 2);
				if (!lua_isboolean(L, -1)) {
					char ep[256];
					snprintf(ep, sizeof(ep),
					         "%s.type[2]", path);
					push_schema_error(
						L, ep,
						"type[2] must be "
						"a boolean",
						lua_typename(L,
						    lua_type(L, -1)),
						"boolean");
					append_error(L, errors_idx);
					lua_pop(L, 2);
					return NULL;
				}
				nullable_from_type =
					lua_toboolean(L, -1);
				lua_pop(L, 2); /* bool + type tbl */
			} else {
				lua_pop(L, 1);
			}
		}

		/*
		 * {oneOf = {...}} — valid when:
		 *   - no type field (type_str == NULL)
		 *   - or type == 'oneof'
		 * If has_oneof and type is something else
		 * → SCHEMA_ERROR.
		 */
		if (has_oneof) {
			if (type_str != NULL &&
			    strcmp(type_str, "oneof") != 0 &&
			    strcmp(type_str, "oneOf") != 0) {
				char ep[256];
				snprintf(ep, sizeof(ep),
				         "%s.oneOf", path);
				push_schema_error(
					L, ep,
					"oneOf key is not allowed "
					"when type is not oneof",
					type_str, "oneof");
				append_error(L, errors_idx);
				return NULL;
			}
			type_str = "oneof";
		}
	} else {
		push_schema_error(
			L, path,
			"Schema must be a string or table",
			lua_typename(L, lua_type(L, def_idx)),
			"string or table"
		);
		append_error(L, errors_idx);
		return NULL;
	}

	if (type_str == NULL)
		type_str = "any";

	/* strip optional '?' suffix */
	bool optional = false;
	char type_buf[64];
	size_t tlen = strlen(type_str);
	if (tlen > 0 && type_str[tlen - 1] == '?') {
		optional = true;
		if (tlen - 1 >= sizeof(type_buf)) {
			push_schema_error(L, path,
				"Type name too long",
				NULL, NULL);
			append_error(L, errors_idx);
			return NULL;
		}
		memcpy(type_buf, type_str, tlen - 1);
		type_buf[tlen - 1] = '\0';
		type_str = type_buf;
	}

	int type_code = cv_type_by_name(type_str);
	if (type_code < 0) {
		push_schema_error(
			L, path,
			"Unknown type",
			type_str,
			"any|boolean|string|number|integer|"
			"unsigned|null|nil|uuid|tuple|"
			"function|map|table|object|"
			"array|oneof|oneOf"
		);
		append_error(L, errors_idx);
		return NULL;
	}

	struct cv_node *n = cv_node_alloc();
	if (n == NULL) {
		*oom = true;
		return NULL;
	}
	n->type     = (enum cv_type)type_code;
	n->optional = optional;
	/* '?' suffix makes value nullable too:
	 * nil is accepted as valid value */
	n->nullable = nullable_from_type || optional;
	cv_node_init_refs(n);

	if (lua_type(L, def_idx) != LUA_TTABLE)
		return n;

	/* optional */
	lua_getfield(L, def_idx, "optional");
	if (lua_isboolean(L, -1))
		n->optional = n->optional ||
		              lua_toboolean(L, -1);
	lua_pop(L, 1);

	/* nullable */
	lua_getfield(L, def_idx, "nullable");
	if (lua_isboolean(L, -1))
		n->nullable = lua_toboolean(L, -1);
	lua_pop(L, 1);

	/* default: key "default" then schema[2] */
	lua_getfield(L, def_idx, "default");
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_rawgeti(L, def_idx, 2);
	}
	if (!lua_isnil(L, -1))
		n->default_ref =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* name */
	lua_getfield(L, def_idx, "name");
	if (lua_isstring(L, -1))
		n->name_ref =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* constraint */
	lua_getfield(L, def_idx, "constraint");
	if (lua_isfunction(L, -1))
		n->constraint_ref =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* transform */
	lua_getfield(L, def_idx, "transform");
	if (lua_isfunction(L, -1))
		n->transform_ref =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* type-specific */
	switch (n->type) {
	case CV_TYPE_STRING: {
		/* min_length / minLength */
		lua_getfield(L, def_idx, "min_length");
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_getfield(L, def_idx, "minLength");
		}
		if (lua_isnumber(L, -1)) {
			n->as.string.has_min_length = true;
			n->as.string.min_length =
				(size_t)lua_tonumber(L, -1);
		}
		lua_pop(L, 1);

		/* max_length / maxLength */
		lua_getfield(L, def_idx, "max_length");
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_getfield(L, def_idx, "maxLength");
		}
		if (lua_isnumber(L, -1)) {
			n->as.string.has_max_length = true;
			n->as.string.max_length =
				(size_t)lua_tonumber(L, -1);
		}
		lua_pop(L, 1);

		/* match / pattern */
		lua_getfield(L, def_idx, "match");
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_getfield(L, def_idx, "pattern");
		}
		if (!lua_isnil(L, -1)) {
			if (lua_type(L, -1) != LUA_TSTRING) {
				char ep[256];
				snprintf(ep, sizeof(ep),
				         "%s.pattern", path);
				push_schema_error(
					L, ep,
					"Pattern must be a string",
					lua_typename(L,
					    lua_type(L, -1)),
					"string"
				);
				append_error(L, errors_idx);
				lua_pop(L, 1);
			} else {
				n->as.string.pattern_ref =
					luaL_ref(L,
					    LUA_REGISTRYINDEX);
			}
		} else {
			lua_pop(L, 1);
		}

		/* enum */
		lua_getfield(L, def_idx, "enum");
		if (lua_type(L, -1) == LUA_TTABLE) {
			int tbl = lua_gettop(L);
			if (!cv_parse_enum(L, tbl,
			        &n->as.string.enums,
			        CV_TYPE_STRING,
			        path, errors_idx)) {
				*oom = true;
				lua_pop(L, 1);
				cv_node_free(L, n);
				return NULL;
			}
		}
		lua_pop(L, 1);
		break;
	}

	case CV_TYPE_NUMBER:
	case CV_TYPE_INTEGER:
	case CV_TYPE_UNSIGNED: {
		/*
		 * Use a local helper to avoid macro inside
		 * switch: get field by key1, fallback key2,
		 * store as lua ref.
		 */
#define GET_NUM_REF(field, key1, key2) \
		lua_getfield(L, def_idx, key1); \
		if (lua_isnil(L, -1)) { \
			lua_pop(L, 1); \
			lua_getfield(L, def_idx, key2); \
		} \
		if (!lua_isnil(L, -1)) \
			n->as.number.field = \
				luaL_ref(L, LUA_REGISTRYINDEX); \
		else \
			lua_pop(L, 1);

		GET_NUM_REF(min_ref, "min",  "minimum")
		GET_NUM_REF(max_ref, "max",  "maximum")
		GET_NUM_REF(gt_ref,  "gt",   "exclusiveMinimum")
		GET_NUM_REF(lt_ref,  "lt",   "exclusiveMaximum")
#undef GET_NUM_REF

		/* enum */
		lua_getfield(L, def_idx, "enum");
		if (lua_type(L, -1) == LUA_TTABLE) {
			int tbl = lua_gettop(L);
			if (!cv_parse_enum(L, tbl,
			        &n->as.number.enums,
			        n->type,
			        path, errors_idx)) {
				*oom = true;
				lua_pop(L, 1);
				cv_node_free(L, n);
				return NULL;
			}
		}
		lua_pop(L, 1);
		break;
	}

	case CV_TYPE_MAP: {
		/* skip_unexpected_check */
		lua_getfield(L, def_idx,
		             "skip_unexpected_check");
		if (lua_isboolean(L, -1))
			n->as.map.skip_unexpected =
				lua_toboolean(L, -1);
		lua_pop(L, 1);

		/* return_unexpected */
		lua_getfield(L, def_idx,
		             "return_unexpected");
		if (lua_isboolean(L, -1))
			n->as.map.return_unexpected =
				lua_toboolean(L, -1);
		lua_pop(L, 1);

		/* rename: parse into sorted array */
		lua_getfield(L, def_idx, "rename");
		if (lua_type(L, -1) == LUA_TTABLE) {
			int rtbl = lua_gettop(L);
			/* count entries */
			int rcount = 0;
			lua_pushnil(L);
			while (lua_next(L, rtbl) != 0) {
				rcount++;
				lua_pop(L, 1);
			}
			if (rcount > 0) {
				n->as.map.rename.entries =
					calloc(rcount,
					    sizeof(struct cv_rename_entry));
				if (n->as.map.rename.entries == NULL) {
					lua_pop(L, 1);
					*oom = true;
					cv_node_free(L, n);
					return NULL;
				}
				n->as.map.rename.count = rcount;
				int ri = 0;
				lua_pushnil(L);
				while (lua_next(L, rtbl) != 0) {
					struct cv_rename_entry *e =
						&n->as.map.rename.entries[ri];
					/* from = key at -2 */
					if (lua_type(L, -2) ==
					    LUA_TNUMBER) {
						e->from.is_int = true;
						e->from.ival = (int)
							lua_tointeger(L, -2);
					} else {
						e->from.is_int = false;
						e->from.sval = strdup(
							lua_tostring(L, -2));
						if (e->from.sval == NULL) {
							lua_pop(L, 2);
							lua_pop(L, 1);
							*oom = true;
							cv_node_free(L, n);
							return NULL;
						}
					}
					/* to = value at -1 */
					if (lua_type(L, -1) ==
					    LUA_TNUMBER) {
						e->to.is_int = true;
						e->to.ival = (int)
							lua_tointeger(L, -1);
					} else {
						e->to.is_int = false;
						e->to.sval = strdup(
							lua_tostring(L, -1));
						if (e->to.sval == NULL) {
							lua_pop(L, 2);
							lua_pop(L, 1);
							*oom = true;
							cv_node_free(L, n);
							return NULL;
						}
					}
					ri++;
					lua_pop(L, 1);
				}
				qsort(n->as.map.rename.entries,
				      rcount,
				      sizeof(struct cv_rename_entry),
				      cv_rename_cmp);
			}
		}
		lua_pop(L, 1);

		/*
		 * items and properties are mutually
		 * exclusive (same as in old validator).
		 */
		lua_getfield(L, def_idx, "items");
		if (!lua_isnil(L, -1)) {
			int items_idx = lua_gettop(L);
			char child_path[512];
			snprintf(child_path,
			         sizeof(child_path),
			         "%s.items", path);
			n->as.map.items =
				cv_compile_node(L, items_idx,
				    child_path,
				    errors_idx, oom);
			lua_pop(L, 1);
			if (*oom) {
				cv_node_free(L, n);
				return NULL;
			}
			break; /* skip properties */
		}
		lua_pop(L, 1);

		/* properties */
		lua_getfield(L, def_idx, "properties");
		if (lua_type(L, -1) == LUA_TTABLE) {
			int props_idx = lua_gettop(L);
			if (!cv_parse_properties(
			        L, props_idx, n,
			        path, errors_idx, oom)) {
				lua_pop(L, 1);
				cv_node_free(L, n);
				return NULL;
			}
		}
		lua_pop(L, 1);

		/*
		 * required: array of non-optional field
		 * names. Processed after properties so
		 * we can look up nodes by key.
		 */
		lua_getfield(L, def_idx, "required");
		if (lua_type(L, -1) == LUA_TTABLE) {
			int rtbl = lua_gettop(L);
			int rlen = (int)lua_objlen(L, rtbl);
			for (int ri = 1; ri <= rlen; ri++) {
				lua_rawgeti(L, rtbl, ri);
				if (lua_type(L, -1) !=
				    LUA_TSTRING) {
					char ep[256];
					snprintf(ep, sizeof(ep),
					    "%s.required[%d]",
					    path, ri);
					push_schema_error(
					    L, ep,
					    "required element must "
					    "be a string",
					    lua_typename(L,
					        lua_type(L, -1)),
					    "string");
					append_error(L, errors_idx);
					lua_pop(L, 1);
					continue;
				}
			const char *rkey =
				lua_tostring(L, -1);
			lua_pop(L, 1);
				/* find property by string key */
				struct cv_node *prop_node = NULL;
				for (int pi = 0;
				     pi < n->as.map.nprops;
				     pi++) {
					if (cv_key_eq_str(
					    &n->as.map.props[pi].key,
					    rkey)) {
						prop_node =
						    n->as.map.props[pi].node;
						break;
					}
				}
				if (prop_node == NULL) {
					char ep[256];
					snprintf(ep, sizeof(ep),
					    "%s.required", path);
					push_schema_error(
					    L, ep,
					    "required field not "
					    "found in properties",
					    rkey, NULL);
					append_error(L, errors_idx);
					continue;
				}
				if (prop_node->optional) {
					char ep[256];
					snprintf(ep, sizeof(ep),
					    "%s.properties.%s",
					    path, rkey);
					push_schema_error(
					    L, ep,
					    "field is in required "
					    "but marked optional",
					    rkey, NULL);
					append_error(L, errors_idx);
					continue;
				}
				prop_node->optional = false;
			}
		}
		lua_pop(L, 1);

		/*
		 * Build aliases: for each rename entry
		 * (from -> to), find prop with key==to
		 * and append 'from' to its aliases list.
		 * If prop not found — silently skip.
		 */
		{
			struct cv_rename *r = &n->as.map.rename;
			for (int ri = 0; ri < r->count; ri++) {
				struct cv_rename_entry *re =
					&r->entries[ri];
				/* find prop matching 'to' */
				int pi;
				for (pi = 0;
				     pi < n->as.map.nprops;
				     pi++) {
					if (cv_key_eq(
					    &n->as.map.props[pi].key,
					    &re->to))
						break;
				}
				if (pi == n->as.map.nprops)
					continue; /* not found */

				struct cv_property *pp =
					&n->as.map.props[pi];
				/* grow aliases array by 1 */
				struct cv_key *na = realloc(
					pp->aliases,
					(pp->naliases + 1) *
					sizeof(struct cv_key));
				if (na == NULL) {
					*oom = true;
					cv_node_free(L, n);
					return NULL;
				}
				pp->aliases = na;
				struct cv_key *ak =
					&pp->aliases[pp->naliases];
				if (re->from.is_int) {
					ak->is_int = true;
					ak->ival   = re->from.ival;
				} else {
					ak->is_int = false;
					ak->sval   = strdup(
						re->from.sval);
					if (ak->sval == NULL) {
						*oom = true;
						cv_node_free(L, n);
						return NULL;
					}
				}
				pp->naliases++;
			}
		}
		break;
	}

	case CV_TYPE_ARRAY: {
		/* min_items / minItems */
		lua_getfield(L, def_idx, "min_length");
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_getfield(L, def_idx, "minItems");
		}
		if (lua_isnumber(L, -1)) {
			n->as.array.has_min_items = true;
			n->as.array.min_items =
				(size_t)lua_tonumber(L, -1);
		}
		lua_pop(L, 1);

		/* max_items / maxItems */
		lua_getfield(L, def_idx, "max_length");
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_getfield(L, def_idx, "maxItems");
		}
		if (lua_isnumber(L, -1)) {
			n->as.array.has_max_items = true;
			n->as.array.max_items =
				(size_t)lua_tonumber(L, -1);
		}
		lua_pop(L, 1);

		/* items schema */
		lua_getfield(L, def_idx, "items");
		if (!lua_isnil(L, -1)) {
			int items_idx = lua_gettop(L);
			char child_path[512];
			snprintf(child_path,
			         sizeof(child_path),
			         "%s.items", path);
			n->as.array.items =
				cv_compile_node(L, items_idx,
				    child_path,
				    errors_idx, oom);
			lua_pop(L, 1);
			if (*oom) {
				cv_node_free(L, n);
				return NULL;
			}
		} else {
			lua_pop(L, 1);
		}
		break;
	}

	case CV_TYPE_ONEOF: {
		/*
		 * Two input formats:
		 *   {type='oneof', variants={...}}
		 *   {oneOf={...}}  -- OpenAPI style
		 * Both result in the same cv_node.
		 */
		lua_getfield(L, def_idx, "variants");
		if (lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_getfield(L, def_idx, "oneOf");
		}
		if (lua_type(L, -1) != LUA_TTABLE) {
			/* variants absent — ok, empty oneof */
			lua_pop(L, 1);
			break;
		}
		int vtbl = lua_gettop(L);
		/* count variants */
		int vcount = 0;
		lua_pushnil(L);
		while (lua_next(L, vtbl) != 0) {
			vcount++;
			lua_pop(L, 1);
		}
		if (vcount == 0) {
			lua_pop(L, 1);
			break;
		}
		n->as.oneof.variants =
			calloc(vcount,
			       sizeof(struct cv_node *));
		if (n->as.oneof.variants == NULL) {
			lua_pop(L, 1);
			*oom = true;
			cv_node_free(L, n);
			return NULL;
		}
		n->as.oneof.nvariants = vcount;
		int vi = 0;
		lua_pushnil(L);
		while (lua_next(L, vtbl) != 0) {
			int val_idx = lua_gettop(L);
			char child_path[512];
			snprintf(child_path,
			         sizeof(child_path),
			         "%s.variants[%d]",
			         path, vi + 1);
			struct cv_node *v =
				cv_compile_node(
				    L, val_idx,
				    child_path,
				    errors_idx, oom);
			if (*oom) {
				lua_pop(L, 2);
				cv_node_free(L, n);
				return NULL;
			}
			n->as.oneof.variants[vi] = v;
			vi++;
			lua_pop(L, 1);
		}
		n->as.oneof.nvariants = vi;
		lua_pop(L, 1); /* variants table */

		/* store ref to original schema table
		 * for oneof_schema in error details */
		lua_pushvalue(L, def_idx);
		n->as.oneof.schema_ref =
			luaL_ref(L, LUA_REGISTRYINDEX);
		break;
	}

	default:
		break;
	}

	return n;
}

/* =========================================================
 * __gc
 * ========================================================= */

static int
cv_node_gc(lua_State *L)
{
	struct cv_node **pp =
		luaL_checkudata(L, 1, CV_NODE_MT);
	if (*pp != NULL) {
		cv_node_free(L, *pp);
		*pp = NULL;
	}
	return 0;
}

/* =========================================================
 * totable helpers
 * ========================================================= */

/*
 * Push cv_key as a Lua value (string or integer).
 */
static void
cv_key_push(lua_State *L, const struct cv_key *k)
{
	if (k->is_int)
		lua_pushinteger(L, (lua_Integer)k->ival);
	else
		lua_pushstring(L, k->sval);
}

/*
 * Set table[cv_key] = value (value at top of stack).
 * Pops the value.
 */
static void
cv_key_settable(lua_State *L, int tbl,
                const struct cv_key *k)
{
	if (k->is_int) {
		lua_rawseti(L, tbl, k->ival);
	} else {
		lua_setfield(L, tbl, k->sval);
	}
}

static void
push_ref_or_nil(lua_State *L, int ref)
{
	if (ref == LUA_NOREF)
		lua_pushnil(L);
	else
		lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
}

static void
push_enum_table(lua_State *L, struct cv_enum *e)
{
	if (e->count == 0 || e->refs == NULL) {
		lua_pushnil(L);
		return;
	}
	lua_createtable(L, e->count, 0);
	for (int i = 0; i < e->count; i++) {
		push_ref_or_nil(L, e->refs[i]);
		lua_rawseti(L, -2, i + 1);
	}
}

/* forward declaration for recursive totable */
static void cv_node_push_table(lua_State *L,
                               struct cv_node *n,
                               bool is_openapi);

static void
cv_node_push_table(lua_State *L, struct cv_node *n,
                   bool is_openapi)
{
	lua_newtable(L);

	/*
	 * type field:
	 *   openapi: map -> "object"
	 *   openapi + nullable: type = [typename, "null"]
	 *   oneof: emit as {oneOf = [...]} top level
	 */
	if (is_openapi && n->type == CV_TYPE_ONEOF) {
		/* handled below — no type field */
	} else {
		const char *tname = cv_type_names[n->type];
		if (is_openapi &&
		    n->type == CV_TYPE_MAP)
			tname = "object";

		if (is_openapi && n->nullable) {
			/* OpenAPI 3.1: type = [tname, "null"] */
			lua_newtable(L);
			lua_pushstring(L, tname);
			lua_rawseti(L, -2, 1);
			lua_pushstring(L, "null");
			lua_rawseti(L, -2, 2);
			lua_setfield(L, -2, "type");
		} else {
			lua_pushstring(L, tname);
			lua_setfield(L, -2, "type");
		}
	}

	if (!is_openapi) {
		lua_pushboolean(L, n->optional);
		lua_setfield(L, -2, "optional");

		lua_pushboolean(L, n->nullable);
		lua_setfield(L, -2, "nullable");
	}

	push_ref_or_nil(L, n->default_ref);
	lua_setfield(L, -2, "default");

	push_ref_or_nil(L, n->name_ref);
	lua_setfield(L, -2, "name");

	push_ref_or_nil(L, n->constraint_ref);
	lua_setfield(L, -2, "constraint");

	push_ref_or_nil(L, n->transform_ref);
	lua_setfield(L, -2, "transform");

	switch (n->type) {
	case CV_TYPE_STRING:
		if (n->as.string.has_min_length) {
			lua_pushnumber(L,
			    (lua_Number)n->as.string.min_length);
			lua_setfield(L, -2,
			    is_openapi ? "minLength"
			               : "min_length");
		}
		if (n->as.string.has_max_length) {
			lua_pushnumber(L,
			    (lua_Number)n->as.string.max_length);
			lua_setfield(L, -2,
			    is_openapi ? "maxLength"
			               : "max_length");
		}
		push_ref_or_nil(L, n->as.string.pattern_ref);
		lua_setfield(L, -2,
		    is_openapi ? "pattern" : "match");
		push_enum_table(L, &n->as.string.enums);
		lua_setfield(L, -2, "enum");
		break;

	case CV_TYPE_NUMBER:
	case CV_TYPE_INTEGER:
	case CV_TYPE_UNSIGNED:
		push_ref_or_nil(L, n->as.number.min_ref);
		lua_setfield(L, -2,
		    is_openapi ? "minimum" : "min");
		push_ref_or_nil(L, n->as.number.max_ref);
		lua_setfield(L, -2,
		    is_openapi ? "maximum" : "max");
		push_ref_or_nil(L, n->as.number.gt_ref);
		lua_setfield(L, -2,
		    is_openapi ? "exclusiveMinimum" : "gt");
		push_ref_or_nil(L, n->as.number.lt_ref);
		lua_setfield(L, -2,
		    is_openapi ? "exclusiveMaximum" : "lt");
		push_enum_table(L, &n->as.number.enums);
		lua_setfield(L, -2, "enum");
		break;

	case CV_TYPE_MAP:
		if (!is_openapi) {
			lua_pushboolean(L,
			    n->as.map.skip_unexpected);
			lua_setfield(L, -2,
			    "skip_unexpected_check");
			lua_pushboolean(L,
			    n->as.map.return_unexpected);
			lua_setfield(L, -2,
			    "return_unexpected");
		}

		/* rename — tarantool only */
		if (!is_openapi &&
		    n->as.map.rename.count > 0) {
			struct cv_rename *r = &n->as.map.rename;
			lua_newtable(L);
			for (int i = 0; i < r->count; i++) {
				struct cv_rename_entry *e =
					&r->entries[i];
				if (e->to.is_int)
					lua_pushinteger(L,
					    (lua_Integer)e->to.ival);
				else
					lua_pushstring(L,
					    e->to.sval);
				if (e->from.is_int)
					lua_rawseti(L, -2,
					    e->from.ival);
				else
					lua_setfield(L, -2,
					    e->from.sval);
			}
			lua_setfield(L, -2, "rename");
		}

		if (n->as.map.items != NULL) {
			cv_node_push_table(L,
			    n->as.map.items, is_openapi);
			/* OpenAPI uses additionalProperties
			 * for wildcard map value schema */
			lua_setfield(L, -2,
			    is_openapi
			    ? "additionalProperties"
			    : "items");
		} else if (n->as.map.nprops > 0) {
			/*
			 * result_tbl is the map schema table
			 * already on the stack. Remember its
			 * absolute index before pushing more.
			 */
			int result_tbl = lua_gettop(L);
			lua_newtable(L); /* properties */
			int props_tbl = lua_gettop(L);
			lua_newtable(L); /* required (tmp) */
			int req_tbl   = lua_gettop(L);
			int req_count = 0;

			for (int i = 0;
			     i < n->as.map.nprops; i++) {
				struct cv_property *pp =
					&n->as.map.props[i];
				cv_node_push_table(L, pp->node,
				    is_openapi);
				cv_key_settable(L, props_tbl,
				    &pp->key);
				if (is_openapi && !pp->node->optional) {
					/*
					 * required only makes sense
					 * for string keys in OpenAPI
					 */
					if (!pp->key.is_int) {
						lua_pushstring(L,
						    pp->key.sval);
						lua_rawseti(L, req_tbl,
						    ++req_count);
					}
				}
			}

			/* attach properties to result */
			lua_pushvalue(L, props_tbl);
			lua_setfield(L, result_tbl,
			    "properties");
			/* attach required if any */
			if (is_openapi && req_count > 0) {
				lua_pushvalue(L, req_tbl);
				lua_setfield(L, result_tbl,
				    "required");
			}
			lua_pop(L, 2); /* props + req tables */
		}
		break;

	case CV_TYPE_ARRAY:
		if (n->as.array.has_min_items) {
			lua_pushnumber(L,
			    (lua_Number)n->as.array.min_items);
			lua_setfield(L, -2,
			    is_openapi ? "minItems"
			               : "min_length");
		}
		if (n->as.array.has_max_items) {
			lua_pushnumber(L,
			    (lua_Number)n->as.array.max_items);
			lua_setfield(L, -2,
			    is_openapi ? "maxItems"
			               : "max_length");
		}
		if (n->as.array.items != NULL) {
			cv_node_push_table(L,
			    n->as.array.items, is_openapi);
			lua_setfield(L, -2, "items");
		}
		break;

	case CV_TYPE_ONEOF:
		if (is_openapi) {
			/* {oneOf = [...]} */
			lua_newtable(L);
			for (int i = 0;
			     i < n->as.oneof.nvariants; i++) {
				cv_node_push_table(L,
				    n->as.oneof.variants[i],
				    true);
				lua_rawseti(L, -2, i + 1);
			}
			lua_setfield(L, -2, "oneOf");
		} else {
			/* {type='oneof', variants={...}} */
			lua_newtable(L);
			for (int i = 0;
			     i < n->as.oneof.nvariants; i++) {
				cv_node_push_table(L,
				    n->as.oneof.variants[i],
				    false);
				lua_rawseti(L, -2, i + 1);
			}
			lua_setfield(L, -2, "variants");
		}
		break;

	default:
		break;
	}
}

/* =========================================================
 * cv_schema_totable(schema[, format]) -> table
 * format: 'tarantool' (default) or 'openapi'
 * ========================================================= */

static int
cv_schema_totable(lua_State *L)
{
	struct cv_node **pp =
		luaL_checkudata(L, 1, CV_NODE_MT);
	bool is_openapi = false;
	if (lua_type(L, 2) == LUA_TSTRING) {
		const char *fmt = lua_tostring(L, 2);
		if (strcmp(fmt, "openapi") == 0)
			is_openapi = true;
	}
	cv_node_push_table(L, *pp, is_openapi);
	return 1;
}

/* =========================================================
 * cv_ctx - validation context
 * ========================================================= */

#define CV_PATH_MAX_DEPTH 128

struct cv_ctx {
	bool  validate_only; /* no mutations/transforms */
	bool  fail_fast;     /* stop at first error
	                      * (internal, for oneof) */
	int   depth;         /* current path depth */
	/*
	 * path[i] holds a shallow (non-owning) copy
	 * of the key at each level. Never call
	 * cv_key_free() on these entries.
	 */
	struct cv_key path[CV_PATH_MAX_DEPTH];
	int   errors_idx;    /* abs. Lua stack index
	                      * of errors table */
};

/* =========================================================
 * Build path string from ctx into buf.
 * Used only when emitting an error.
 * ========================================================= */

static void
cv_ctx_path(const struct cv_ctx *ctx,
            char *buf, size_t bufsz)
{
	int pos = 0;
	pos += snprintf(buf + pos,
	                bufsz - (size_t)pos, "$");
	for (int i = 0; i < ctx->depth && pos < (int)bufsz - 1;
	     i++) {
		const struct cv_key *k = &ctx->path[i];
		if (k->is_int) {
			pos += snprintf(buf + pos,
			    bufsz - (size_t)pos,
			    "[%d]", k->ival);
		} else {
			pos += snprintf(buf + pos,
			    bufsz - (size_t)pos,
			    ".%s", k->sval);
		}
	}
}

/* =========================================================
 * Push a validation error onto ctx->errors_idx.
 * Compatible with old validator format:
 *   {path, type, message, name?, details={...}}
 * Does nothing when fail_fast.
 *
 * Returns absolute stack index of the details table
 * so callers can populate it further.
 * Returns 0 if fail_fast (nothing pushed).
 * ========================================================= */

/*
 * Pushes error onto errors table and leaves the
 * details table on top of the Lua stack.
 * Caller MUST pop details (lua_pop(L,1)) when done.
 * Returns absolute stack index of details table,
 * or 0 if fail_fast (nothing pushed, stack unchanged).
 */
static int
cv_ctx_push_error(lua_State *L,
                  const struct cv_ctx *ctx,
                  const struct cv_node *n,
                  const char *code,
                  const char *message)
{
	if (ctx->fail_fast)
		return 0;

	char path_buf[512];
	cv_ctx_path(ctx, path_buf, sizeof(path_buf));

	/* build error table */
	lua_newtable(L);
	int err_idx = lua_gettop(L);

	lua_pushstring(L, path_buf);
	lua_setfield(L, err_idx, "path");

	lua_pushstring(L, code);
	lua_setfield(L, err_idx, "type");

	lua_pushstring(L, message);
	lua_setfield(L, err_idx, "message");

	/* name from schema node */
	if (n != NULL && n->name_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->name_ref);
		lua_setfield(L, err_idx, "name");
	}

	/* build empty details table */
	lua_newtable(L);
	lua_setfield(L, err_idx, "details");

	/* append error to errors table */
	int eidx = (int)lua_objlen(L,
	    ctx->errors_idx) + 1;
	lua_rawseti(L, ctx->errors_idx, eidx);
	/* err_table is now stored, stack is clean */

	/* fetch details back for caller to populate */
	lua_rawgeti(L, ctx->errors_idx, eidx);
	lua_getfield(L, -1, "details");
	/* remove the err table copy below details */
	lua_remove(L, -2);
	/* details is now on top */
	int det_idx = lua_gettop(L);

	return det_idx;
}

/* =========================================================
 * Forward declarations
 * ========================================================= */

static bool cv_check_node(lua_State *L,
    struct cv_ctx *ctx, int data_idx,
    const struct cv_node *n);

/* =========================================================
 * cv_check_scalar
 * ========================================================= */

static bool
cv_check_scalar(lua_State *L, struct cv_ctx *ctx,
                int data_idx,
                const struct cv_node *n)
{
	int ltype = lua_type(L, data_idx);
	bool ok = false;

	switch (n->type) {
	case CV_TYPE_ANY:
		ok = true;
		break;
	case CV_TYPE_BOOLEAN:
		ok = (ltype == LUA_TBOOLEAN);
		break;
	case CV_TYPE_STRING:
		ok = (ltype == LUA_TSTRING);
		break;
	case CV_TYPE_NUMBER:
		/* number: Lua number OR int64 OR uint64 */
		ok = (ltype == LUA_TNUMBER ||
		      cv_is_int64(L, data_idx) ||
		      cv_is_uint64(L, data_idx));
		break;
	case CV_TYPE_INTEGER:
		/* integer: Lua number with floor==val,
		 * OR int64_t OR uint64_t cdata */
		if (ltype == LUA_TNUMBER) {
			lua_Number v =
				lua_tonumber(L, data_idx);
			ok = (v == (lua_Number)(lua_Integer)v);
		} else {
			ok = (cv_is_int64(L, data_idx) ||
			      cv_is_uint64(L, data_idx));
		}
		break;
	case CV_TYPE_UNSIGNED:
		/* unsigned: Lua number >= 0 integer,
		 * OR uint64_t, OR int64_t >= 0 */
		if (ltype == LUA_TNUMBER) {
			lua_Number v =
				lua_tonumber(L, data_idx);
			ok = (v >= 0 &&
			      v == (lua_Number)(lua_Integer)v);
		} else if (cv_is_uint64(L, data_idx)) {
			ok = true;
		} else if (cv_is_int64(L, data_idx)) {
			int64_t v =
				*(int64_t *)luaL_checkcdata(
				    L, data_idx, NULL);
			ok = (v >= 0);
		} else {
			ok = false;
		}
		break;
	case CV_TYPE_NIL:
		ok = (ltype == LUA_TNIL);
		break;
	case CV_TYPE_NULL:
		/* null accepts Lua nil OR box.NULL */
		if (ltype == LUA_TNIL) {
			ok = true;
		} else if (cv_ref_box_null != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    cv_ref_box_null);
			ok = lua_equal(L, data_idx, -1);
			lua_pop(L, 1);
		} else {
			ok = false;
		}
		break;
	case CV_TYPE_UUID:
		/* uuid: call uuid_is() if available */
		if (cv_ref_uuid_is != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    cv_ref_uuid_is);
			lua_pushvalue(L, data_idx);
			lua_call(L, 1, 1);
			ok = lua_toboolean(L, -1);
			lua_pop(L, 1);
		} else {
			ok = luaL_iscdata(L, data_idx);
		}
		break;
	case CV_TYPE_TUPLE:
		/* tuple: call tuple_is() if available */
		if (cv_ref_tuple_is != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    cv_ref_tuple_is);
			lua_pushvalue(L, data_idx);
			lua_call(L, 1, 1);
			ok = lua_toboolean(L, -1);
			lua_pop(L, 1);
		} else {
			ok = luaL_iscdata(L, data_idx);
		}
		break;
	case CV_TYPE_FUNCTION:
		/* function or callable (__call) */
		if (ltype == LUA_TFUNCTION) {
			ok = true;
		} else if (lua_getmetatable(
		               L, data_idx)) {
			lua_getfield(L, -1, "__call");
			ok = (lua_type(L, -1) ==
			      LUA_TFUNCTION);
			lua_pop(L, 2); /* __call + mt */
		} else {
			ok = false;
		}
		break;
	default:
		ok = false;
		break;
	}

	if (!ok) {
		char msg[256];
		/* actual_type: for cdata use typestr */
		const char *actual_type =
			lua_typename(L, ltype);
		snprintf(msg, sizeof(msg),
		    "Wrong type, expected %s, got %s",
		    cv_type_names[n->type],
		    actual_type);
		int det = cv_ctx_push_error(L, ctx, n,
		    "TYPE_ERROR", msg);
		if (det != 0) {
			lua_pushstring(L,
			    cv_type_names[n->type]);
			lua_setfield(L, det,
			    "expected_type");
			lua_pushstring(L, actual_type);
			lua_setfield(L, det,
			    "actual_type");
			lua_pushvalue(L, data_idx);
			lua_setfield(L, det, "value");
			/* cdata_type for cdata values */
			if (luaL_iscdata(L, data_idx)) {
				cv_push_cdata_typestr(L,
				    data_idx);
				lua_setfield(L, det,
				    "cdata_type");
			}
			lua_pop(L, 1); /* pop details */
		}
		return false;
	}

	/* string constraints */
	if (n->type == CV_TYPE_STRING) {
		size_t slen = 0;
		lua_tolstring(L, data_idx, &slen);

		if (n->as.string.has_min_length &&
		    slen < n->as.string.min_length) {
			int det = cv_ctx_push_error(L, ctx,
			    n, "VALUE_ERROR",
			    "Value len is less than"
			    " minimum");
			if (det != 0) {
				lua_pushnumber(L, (lua_Number)
				    n->as.string.min_length);
				lua_setfield(L, det, "min_len");
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pop(L, 1);
			}
			return false;
		}
		if (n->as.string.has_max_length &&
		    slen > n->as.string.max_length) {
			int det = cv_ctx_push_error(L, ctx,
			    n, "VALUE_ERROR",
			    "Value len exceeded maximum");
			if (det != 0) {
				lua_pushnumber(L, (lua_Number)
				    n->as.string.max_length);
				lua_setfield(L, det, "max_len");
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pop(L, 1);
			}
			return false;
		}
		/* pattern match via string.find */
		if (n->as.string.pattern_ref !=
		    LUA_NOREF) {
			lua_getglobal(L, "string");
			lua_getfield(L, -1, "find");
			lua_remove(L, -2);
			lua_pushvalue(L, data_idx);
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    n->as.string.pattern_ref);
			bool matched = true;
			if (lua_pcall(L, 2, 1, 0) == 0) {
				matched = !lua_isnil(L, -1);
				lua_pop(L, 1);
			} else {
				lua_pop(L, 1); /* err msg */
			}
			if (!matched) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value doesn't match"
				    " the regexp");
				if (det != 0) {
					lua_rawgeti(L,
					    LUA_REGISTRYINDEX,
					    n->as.string
					    .pattern_ref);
					lua_setfield(L, det,
					    "match_string");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				return false;
			}
		}
		/* string enum */
		if (n->as.string.enums.count > 0) {
			bool found = false;
			for (int i = 0;
			     i < n->as.string.enums.count;
			     i++) {
				lua_rawgeti(L,
				    LUA_REGISTRYINDEX,
				    n->as.string.enums.refs[i]);
				if (lua_equal(L,
				    data_idx, -1)) {
					found = true;
					lua_pop(L, 1);
					break;
				}
				lua_pop(L, 1);
			}
			if (!found) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value does not belong"
				    " to set");
				if (det != 0) {
					/* enum_variants */
					lua_newtable(L);
					for (int i = 0; i <
					    n->as.string
					    .enums.count;
					    i++) {
						lua_rawgeti(L,
						    LUA_REGISTRYINDEX,
						    n->as.string
						    .enums.refs[i]);
						lua_rawseti(L,
						    -2, i + 1);
					}
					lua_setfield(L, det,
					    "enum_variants");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				return false;
			}
		}
	}

	/* number constraints */
	if (n->type == CV_TYPE_NUMBER ||
	    n->type == CV_TYPE_INTEGER ||
	    n->type == CV_TYPE_UNSIGNED) {
		/* gt */
		if (n->as.number.gt_ref != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    n->as.number.gt_ref);
			bool fail = !lua_lessthan(L, -1,
			    data_idx);
			if (fail) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value is too small");
				if (det != 0) {
					lua_pushvalue(L, -2);
					lua_setfield(L, det,
					    "gt");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				lua_pop(L, 1);
				return false;
			}
			lua_pop(L, 1);
		}
		/* lt */
		if (n->as.number.lt_ref != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    n->as.number.lt_ref);
			bool fail = !lua_lessthan(L,
			    data_idx, -1);
			if (fail) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value is too big");
				if (det != 0) {
					lua_pushvalue(L, -2);
					lua_setfield(L, det,
					    "lt");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				lua_pop(L, 1);
				return false;
			}
			lua_pop(L, 1);
		}
		/* min */
		if (n->as.number.min_ref != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    n->as.number.min_ref);
			bool fail = lua_lessthan(L,
			    data_idx, -1);
			if (fail) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value is less than"
				    " minimum");
				if (det != 0) {
					lua_pushvalue(L, -2);
					lua_setfield(L, det,
					    "min");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				lua_pop(L, 1);
				return false;
			}
			lua_pop(L, 1);
		}
		/* max */
		if (n->as.number.max_ref != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    n->as.number.max_ref);
			bool fail = lua_lessthan(L, -1,
			    data_idx);
			if (fail) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value exceeded maximum");
				if (det != 0) {
					lua_pushvalue(L, -2);
					lua_setfield(L, det,
					    "max");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				lua_pop(L, 1);
				return false;
			}
			lua_pop(L, 1);
		}
		/* number enum */
		if (n->as.number.enums.count > 0) {
			bool found = false;
			for (int i = 0;
			     i < n->as.number.enums.count;
			     i++) {
				lua_rawgeti(L,
				    LUA_REGISTRYINDEX,
				    n->as.number.enums.refs[i]);
				if (lua_equal(L,
				    data_idx, -1)) {
					found = true;
					lua_pop(L, 1);
					break;
				}
				lua_pop(L, 1);
			}
			if (!found) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "VALUE_ERROR",
				    "Value does not belong"
				    " to set");
				if (det != 0) {
					lua_newtable(L);
					for (int i = 0; i <
					    n->as.number
					    .enums.count;
					    i++) {
						lua_rawgeti(L,
						    LUA_REGISTRYINDEX,
						    n->as.number
						    .enums.refs[i]);
						lua_rawseti(L,
						    -2, i + 1);
					}
					lua_setfield(L, det,
					    "enum_variants");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				return false;
			}
		}
	}

	/* constraint callback via pcall */
	if (n->constraint_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->constraint_ref);
		lua_pushvalue(L, data_idx);
		if (lua_pcall(L, 1, 0, 0) != 0) {
			int errmsg = lua_gettop(L);
			int det = cv_ctx_push_error(L, ctx,
			    n, "CONSTRAINT_ERROR",
			    "Field constraint detected"
			    " error");
			if (det != 0) {
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pushvalue(L, errmsg);
				lua_setfield(L, det,
				    "constraint_error");
				lua_pop(L, 1);
			}
			lua_pop(L, 1); /* errmsg */
			return false;
		}
	}

	/* transform via pcall */
	if (!ctx->validate_only &&
	    n->transform_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->transform_ref);
		lua_pushvalue(L, data_idx);
		if (lua_pcall(L, 1, 1, 0) == 0) {
			lua_replace(L, data_idx);
		} else {
			int errmsg = lua_gettop(L);
			int det = cv_ctx_push_error(L, ctx,
			    n, "TRANSFORM_ERROR",
			    "Field transformation failed");
			if (det != 0) {
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pushvalue(L, errmsg);
				lua_setfield(L, det,
				    "transform_error");
				lua_pop(L, 1);
			}
			lua_pop(L, 1); /* errmsg */
			return false;
		}
	}

	return true;
}

/* =========================================================
 * cv_check_array
 * ========================================================= */

static bool
cv_check_array(lua_State *L, struct cv_ctx *ctx,
               int data_idx,
               const struct cv_node *n)
{
	if (lua_type(L, data_idx) != LUA_TTABLE) {
		char msg[256];
		const char *actual_type =
			lua_typename(L, lua_type(L, data_idx));
		snprintf(msg, sizeof(msg), "Wrong type, expected array, got %s",
			 actual_type);
		int det = cv_ctx_push_error(L, ctx, n, "TYPE_ERROR", msg);
		if (det != 0) {
			lua_pushstring(L, "array");
			lua_setfield(L, det,
			    "expected_type");
			lua_pushstring(L, actual_type);
			lua_setfield(L, det,
			    "actual_type");
			lua_pushvalue(L, data_idx);
			lua_setfield(L, det, "value");
			lua_pop(L, 1);
		}
		return false;
	}

	/* Check that all keys are integers (reject maps) */
	lua_pushnil(L);
	while (lua_next(L, data_idx) != 0) {
		lua_pop(L, 1); /* pop value, keep key */
		if (lua_type(L, -1) != LUA_TNUMBER) {
			lua_pop(L, 1); /* pop key */
			int det = cv_ctx_push_error(L, ctx, n,
			    "ARRAY_EXPECTED",
			    "Unexpected map");
			if (det != 0) {
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pop(L, 1);
			}
			return false;
		}
	}

	int len = (int)lua_objlen(L, data_idx);

	if (n->as.array.has_min_items &&
	    (size_t)len < n->as.array.min_items) {
		int det = cv_ctx_push_error(L, ctx, n,
		    "VALUE_ERROR",
		    "Value len is less than minimum");
		if (det != 0) {
			lua_pushnumber(L, (lua_Number)
			    n->as.array.min_items);
			lua_setfield(L, det, "min_len");
			lua_pushvalue(L, data_idx);
			lua_setfield(L, det, "value");
			lua_pop(L, 1);
		}
		return false;
	}
	if (n->as.array.has_max_items &&
	    (size_t)len > n->as.array.max_items) {
		int det = cv_ctx_push_error(L, ctx, n,
		    "VALUE_ERROR",
		    "Value len exceeded maximum");
		if (det != 0) {
			lua_pushnumber(L, (lua_Number)
			    n->as.array.max_items);
			lua_setfield(L, det, "max_len");
			lua_pushvalue(L, data_idx);
			lua_setfield(L, det, "value");
			lua_pop(L, 1);
		}
		return false;
	}

	bool ok = true;
	if (n->as.array.items != NULL) {
		for (int i = 1; i <= len; i++) {
			lua_rawgeti(L, data_idx, i);
			int val_idx = lua_gettop(L);

			/* push path segment */
			if (ctx->depth < CV_PATH_MAX_DEPTH) {
				ctx->path[ctx->depth].is_int =
					true;
				ctx->path[ctx->depth].ival = i;
				ctx->depth++;
			}

			bool r = cv_check_node(L, ctx,
			    val_idx, n->as.array.items);

			if (ctx->depth > 0)
				ctx->depth--;

			if (r && !ctx->validate_only) {
				/* write back (may be replaced
				 * by transform) */
				lua_pushvalue(L, val_idx);
				lua_rawseti(L, data_idx, i);
			}
			lua_pop(L, 1);

			if (!r) {
				ok = false;
				if (ctx->fail_fast)
					return false;
			}
		}
	}

	/* constraint on the array itself */
	if (ok && n->constraint_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->constraint_ref);
		lua_pushvalue(L, data_idx);
		if (lua_pcall(L, 1, 0, 0) != 0) {
			int errmsg = lua_gettop(L);
			int det = cv_ctx_push_error(L, ctx,
			    n, "CONSTRAINT_ERROR",
			    "Field constraint detected"
			    " error");
			if (det != 0) {
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pushvalue(L, errmsg);
				lua_setfield(L, det,
				    "constraint_error");
				lua_pop(L, 1);
			}
			lua_pop(L, 1); /* errmsg */
			return false;
		}
	}

	/* transform on the array itself */
	if (ok && !ctx->validate_only &&
	    n->transform_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->transform_ref);
		lua_pushvalue(L, data_idx);
		lua_call(L, 1, 0);
	}

	return ok;
}

/* =========================================================
 * cv_check_map
 * ========================================================= */

/*
 * Look up a cv_key in a Lua table at tbl_idx.
 * Pushes value on stack (may be nil). Returns true
 * if the key was integer (use lua_rawgeti result),
 * false for string (use lua_getfield result).
 */
static void
cv_map_getfield(lua_State *L, int tbl_idx,
                const struct cv_key *k)
{
	if (k->is_int)
		lua_rawgeti(L, tbl_idx, k->ival);
	else
		lua_getfield(L, tbl_idx, k->sval);
}

/*
 * Set tbl[key] = value (value at top), pops value.
 */
static void
cv_map_setfield(lua_State *L, int tbl_idx,
                const struct cv_key *k)
{
	if (k->is_int) {
		lua_rawseti(L, tbl_idx, k->ival);
	} else {
		lua_setfield(L, tbl_idx, k->sval);
	}
}

/*
 * Remove key from table (set to nil).
 */
static void
cv_map_delfield(lua_State *L, int tbl_idx,
                const struct cv_key *k)
{
	lua_pushnil(L);
	cv_map_setfield(L, tbl_idx, k);
}

static bool
cv_check_map(lua_State *L, struct cv_ctx *ctx,
             int data_idx,
             const struct cv_node *n)
{
	if (lua_type(L, data_idx) != LUA_TTABLE) {
		char msg[256];
		const char *actual_type =
			lua_typename(L, lua_type(L, data_idx));
		snprintf(msg, sizeof(msg), "Wrong type, expected map, got %s",
			 actual_type);
		int det = cv_ctx_push_error(L, ctx, n, "TYPE_ERROR", msg);
		if (det != 0) {
			lua_pushstring(L, "map");
			lua_setfield(L, det,
			    "expected_type");
			lua_pushstring(L, actual_type);
			lua_setfield(L, det,
			    "actual_type");
			lua_pushvalue(L, data_idx);
			lua_setfield(L, det, "value");
			lua_pop(L, 1);
		}
		return false;
	}

	bool ok = true;

	/* --- map with items (wildcard schema) --- */
	if (n->as.map.items != NULL) {
		lua_pushnil(L);
		while (lua_next(L, data_idx) != 0) {
			/* key at -2, value at -1 */
			int val_idx = lua_gettop(L);

			/* push path segment from key */
			if (ctx->depth < CV_PATH_MAX_DEPTH) {
				struct cv_key *pk =
					&ctx->path[ctx->depth];
				if (lua_type(L, -2) ==
				    LUA_TNUMBER) {
					pk->is_int = true;
					pk->ival = (int)
					    lua_tointeger(L, -2);
				} else {
					pk->is_int = false;
					pk->sval = (char *)
					    lua_tostring(L, -2);
				}
				ctx->depth++;
			}

			bool r = cv_check_node(L, ctx,
			    val_idx, n->as.map.items);

			if (ctx->depth > 0)
				ctx->depth--;

			lua_pop(L, 1); /* pop value */

			if (!r) {
				ok = false;
				if (ctx->fail_fast) {
					/* pop key */
					lua_pop(L, 1);
					return false;
				}
			}
		}
		return ok;
	}

	/* --- step 1: iterate props --- */
	for (int i = 0; i < n->as.map.nprops; i++) {
		struct cv_property *pp =
			&n->as.map.props[i];

		/*
		 * Look up value: aliases (rename) have
		 * priority over primary key. This matches
		 * old validator behaviour: rename is
		 * applied unconditionally.
		 */
		int val_idx = 0;
		const struct cv_key *found_as = NULL;

		for (int ai = 0;
		     ai < pp->naliases; ai++) {
			cv_map_getfield(L, data_idx,
			    &pp->aliases[ai]);
			if (!lua_isnil(L, -1)) {
				found_as =
				    &pp->aliases[ai];
				val_idx = lua_gettop(L);
				break;
			}
			lua_pop(L, 1);
		}

		if (found_as == NULL) {
			/* no alias found, try primary key */
			cv_map_getfield(L, data_idx,
			    &pp->key);
			val_idx = lua_gettop(L);
			if (!lua_isnil(L, val_idx)) {
				found_as = &pp->key;
			} else {
				lua_pop(L, 1);
				val_idx = 0;
			}
		}

		if (found_as == NULL) {
			/* not found anywhere */
			if (pp->node->optional) {
				continue;
			}
			if (pp->node->default_ref !=
			    LUA_NOREF) {
				if (!ctx->validate_only) {
					/*
					 * Apply default via deepcopy
					 * so each check() call gets
					 * its own independent copy.
					 * Then run cv_check_node on
					 * the copy so nested defaults
					 * are applied too.
					 */
					int top_before =
					    lua_gettop(L);
					lua_rawgeti(L,
					    LUA_REGISTRYINDEX,
					    cv_ref_deepcopy);
					lua_rawgeti(L,
					    LUA_REGISTRYINDEX,
					    pp->node->default_ref);
					luaT_call(L, 1, 1);
					int dval_idx = lua_gettop(L);
					if (ctx->depth <
					    CV_PATH_MAX_DEPTH) {
						ctx->path[ctx->depth]
						    = pp->key;
						ctx->depth++;
					}
					bool r = cv_check_node(L,
					    ctx, dval_idx,
					    pp->node);
					if (ctx->depth > 0)
						ctx->depth--;
					if (r) {
						/* write back: value at
						 * dval_idx may have been
						 * updated by transform */
						lua_pushvalue(L, dval_idx);
						cv_map_setfield(L,
						    data_idx, &pp->key);
					}
					lua_pop(L, 1); /* pop dval */
					if (!r) {
						ok = false;
						if (ctx->fail_fast)
							return false;
					}
				}
				/* validate_only: default
				 * present = ok */
				continue;
			}
			/* truly missing */
			if (ctx->depth < CV_PATH_MAX_DEPTH) {
				ctx->path[ctx->depth] = pp->key;
				ctx->depth++;
			}
			{
				int det = cv_ctx_push_error(
				    L, ctx, pp->node,
				    "UNDEFINED_VALUE",
				    "Undefined value");
				if (det != 0)
					lua_pop(L, 1);
			}
			if (ctx->depth > 0)
				ctx->depth--;
			ok = false;
			if (ctx->fail_fast)
				return false;
			continue;
		}

		/* found — maybe rename */
		if (!ctx->validate_only &&
		    found_as != &pp->key) {
			/* move alias key -> primary key */
			lua_pushvalue(L, val_idx);
			cv_map_setfield(L, data_idx,
			    &pp->key);
			cv_map_delfield(L, data_idx,
			    found_as);
			/* update val_idx: value is now
			 * at primary key */
			lua_pop(L, 1);
			cv_map_getfield(L, data_idx,
			    &pp->key);
			val_idx = lua_gettop(L);
		}

		/* push path segment */
		if (ctx->depth < CV_PATH_MAX_DEPTH) {
			ctx->path[ctx->depth] = pp->key;
			ctx->depth++;
		}

		bool r = cv_check_node(L, ctx,
		    val_idx, pp->node);

		if (ctx->depth > 0)
			ctx->depth--;

		lua_pop(L, 1); /* pop value */

		if (!r) {
			ok = false;
			if (ctx->fail_fast)
				return false;
		}
	}

	/* --- step 2: unexpected keys --- */
	if (!n->as.map.skip_unexpected &&
	    !n->as.map.return_unexpected) {
		/*
		 * Check for keys not in props
		 * (and not an alias of any prop).
		 */
		lua_pushnil(L);
		while (lua_next(L, data_idx) != 0) {
			lua_pop(L, 1); /* pop value */
			/* check key at -1 */
			bool known = false;
			for (int i = 0;
			     i < n->as.map.nprops; i++) {
				struct cv_property *pp =
					&n->as.map.props[i];
				struct cv_key k;
				if (lua_type(L, -1) ==
				    LUA_TNUMBER) {
					k.is_int = true;
					k.ival = (int)
					    lua_tointeger(L, -1);
				} else {
					k.is_int = false;
					k.sval = (char *)
					    lua_tostring(L, -1);
				}
				if (cv_key_eq(&pp->key, &k)) {
					known = true;
					break;
				}
				for (int ai = 0;
				     ai < pp->naliases;
				     ai++) {
					if (cv_key_eq(
					    &pp->aliases[ai],
					    &k)) {
						known = true;
						break;
					}
				}
				if (known)
					break;
			}
			if (!known) {
				int det = cv_ctx_push_error(
				    L, ctx, n,
				    "UNEXPECTED_KEY",
				    "Unexpected key");
				if (det != 0) {
					lua_pushvalue(L, -2);
					lua_setfield(L, det,
					    "unexpected_key");
					lua_pushvalue(L,
					    data_idx);
					lua_setfield(L, det,
					    "value");
					lua_pop(L, 1);
				}
				ok = false;
				if (ctx->fail_fast) {
					lua_pop(L, 1);
					return false;
				}
			}
		}
	} else if (n->as.map.skip_unexpected &&
	           !n->as.map.return_unexpected) {
		/*
		 * Collect unknown keys, then delete.
		 * Two-pass to avoid modifying table
		 * during iteration.
		 */
		int top_before = lua_gettop(L);
		lua_pushnil(L);
		while (lua_next(L, data_idx) != 0) {
			lua_pop(L, 1);
			bool known = false;
			for (int i = 0;
			     i < n->as.map.nprops; i++) {
				struct cv_property *pp =
					&n->as.map.props[i];
				struct cv_key k;
				if (lua_type(L, -1) ==
				    LUA_TNUMBER) {
					k.is_int = true;
					k.ival = (int)
					    lua_tointeger(L, -1);
				} else {
					k.is_int = false;
					k.sval = (char *)
					    lua_tostring(L, -1);
				}
				if (cv_key_eq(&pp->key, &k)) {
					known = true;
					break;
				}
				for (int ai = 0;
				     ai < pp->naliases;
				     ai++) {
					if (cv_key_eq(
					    &pp->aliases[ai],
					    &k)) {
						known = true;
						break;
					}
				}
				if (known)
					break;
			}
			if (!known)
				lua_pushvalue(L, -1); /* dup key */
		}
		/* stack: [... unknown_key1, ...] */
		int top_after = lua_gettop(L);
		for (int i = top_before + 1;
		     i <= top_after; i++) {
			lua_pushnil(L);
			/* set tbl[key]=nil */
			if (lua_type(L, i) == LUA_TNUMBER) {
				lua_rawseti(L, data_idx,
				    (int)lua_tointeger(L, i));
			} else {
				lua_setfield(L, data_idx,
				    lua_tostring(L, i));
			}
		}
		lua_settop(L, top_before);
	}
	/* return_unexpected: do nothing extra */

	/* --- step 3: constraint via pcall --- */
	if (ok && n->constraint_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->constraint_ref);
		lua_pushvalue(L, data_idx);
		if (lua_pcall(L, 1, 0, 0) != 0) {
			int errmsg = lua_gettop(L);
			int det = cv_ctx_push_error(L, ctx,
			    n, "CONSTRAINT_ERROR",
			    "Field constraint detected"
			    " error");
			if (det != 0) {
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pushvalue(L, errmsg);
				lua_setfield(L, det,
				    "constraint_error");
				lua_pop(L, 1);
			}
			lua_pop(L, 1); /* errmsg */
			return false;
		}
	}

	/* --- step 4: transform via pcall --- */
	if (ok && !ctx->validate_only &&
	    n->transform_ref != LUA_NOREF) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    n->transform_ref);
		lua_pushvalue(L, data_idx);
		if (lua_pcall(L, 1, 0, 0) != 0) {
			int errmsg = lua_gettop(L);
			int det = cv_ctx_push_error(L, ctx,
			    n, "TRANSFORM_ERROR",
			    "Field transformation failed");
			if (det != 0) {
				lua_pushvalue(L, data_idx);
				lua_setfield(L, det, "value");
				lua_pushvalue(L, errmsg);
				lua_setfield(L, det,
				    "transform_error");
				lua_pop(L, 1);
			}
			lua_pop(L, 1); /* errmsg */
			return false;
		}
	}

	return ok;
}

/* =========================================================
 * cv_check_oneof
 * ========================================================= */

static bool
cv_check_oneof(lua_State *L, struct cv_ctx *ctx,
               int data_idx,
               const struct cv_node *n)
{
	/* dry-run: find first matching variant */
	int found = -1;
	for (int i = 0;
	     i < n->as.oneof.nvariants; i++) {
		struct cv_ctx dry = *ctx;
		dry.validate_only = true;
		dry.fail_fast     = true;
		if (cv_check_node(L, &dry, data_idx,
		        n->as.oneof.variants[i])) {
			found = i;
			break;
		}
	}

	if (found >= 0) {
		/* full run with original ctx */
		return cv_check_node(L, ctx, data_idx,
		    n->as.oneof.variants[found]);
	}

	/*
	 * No variant matched.
	 * Second pass: collect all errors from all
	 * variants (validate_only, no mutations).
	 */
	if (!ctx->fail_fast) {
		struct cv_ctx err_ctx = *ctx;
		err_ctx.validate_only = true;
		err_ctx.fail_fast     = false;
		for (int i = 0;
		     i < n->as.oneof.nvariants; i++) {
			cv_check_node(L, &err_ctx,
			    data_idx,
			    n->as.oneof.variants[i]);
		}
	}

	/* push ONEOF_ERROR with details */
	int det = cv_ctx_push_error(L, ctx, n,
	    "ONEOF_ERROR",
	    "The object isn't fit for any variant");
	if (det != 0) {
		lua_pushvalue(L, data_idx);
		lua_setfield(L, det, "value");
		/* oneof_schema: original Lua table */
		if (n->as.oneof.schema_ref !=
		    LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    n->as.oneof.schema_ref);
			lua_setfield(L, det,
			    "oneof_schema");
		}
		lua_pop(L, 1); /* pop details */
	}
	return false;
}

/* =========================================================
 * cv_check_node - dispatcher
 * ========================================================= */

static bool
cv_check_node(lua_State *L, struct cv_ctx *ctx,
              int data_idx,
              const struct cv_node *n)
{
	/* nullable: nil is always ok */
	if (n->nullable) {
		bool is_null =
			(lua_type(L, data_idx) == LUA_TNIL);
		/* also treat box.NULL as null */
		if (!is_null &&
		    cv_ref_box_null != LUA_NOREF) {
			lua_rawgeti(L, LUA_REGISTRYINDEX,
			    cv_ref_box_null);
			is_null = lua_equal(L,
			    data_idx, -1);
			lua_pop(L, 1);
		}
		if (is_null)
			return true;
	}

	/*
	 * nil value for a required non-null type:
	 * report UNDEFINED_VALUE, matching the old
	 * validator behaviour (bench/validator.lua:475).
	 */
	if (lua_type(L, data_idx) == LUA_TNIL &&
	    n->type != CV_TYPE_ANY  &&
	    n->type != CV_TYPE_NULL &&
	    n->type != CV_TYPE_NIL  &&
	    !n->optional) {
		int det = cv_ctx_push_error(L, ctx, n,
		    "UNDEFINED_VALUE",
		    "Undefined value");
		if (det != 0)
			lua_pop(L, 1);
		return false;
	}

	switch (n->type) {
	case CV_TYPE_MAP:
		return cv_check_map(L, ctx,
		    data_idx, n);
	case CV_TYPE_ARRAY:
		return cv_check_array(L, ctx,
		    data_idx, n);
	case CV_TYPE_ONEOF:
		return cv_check_oneof(L, ctx,
		    data_idx, n);
	default:
		return cv_check_scalar(L, ctx,
		    data_idx, n);
	}
}

/* =========================================================
 * schema:check(data [, opts]) -> ok, errors
 * opts: {validate_only=bool}
 * ========================================================= */

static int
cv_schema_check(lua_State *L)
{
	struct cv_node **pp =
		luaL_checkudata(L, 1, CV_NODE_MT);
	/* arg 2: data (any value) */
	/* arg 3: opts table (optional) */

	bool validate_only = false;
	bool raise_errors  = false;
	if (lua_type(L, 3) == LUA_TTABLE) {
		lua_getfield(L, 3, "validate_only");
		if (lua_isboolean(L, -1))
			validate_only =
				lua_toboolean(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 3, "raise_errors");
		if (lua_isboolean(L, -1))
			raise_errors =
				lua_toboolean(L, -1);
		lua_pop(L, 1);
	}

	/*
	 * Top-level default: if data is nil and
	 * schema has a default, apply it before
	 * validation. Use deepcopy so each call
	 * gets an independent copy of the default.
	 */
	if (lua_isnil(L, 2) &&
	    (*pp)->default_ref != LUA_NOREF &&
	    !validate_only) {
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    cv_ref_deepcopy);
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		    (*pp)->default_ref);
		luaT_call(L, 1, 1);
		lua_replace(L, 2);
	}

	/* errors table */
	lua_newtable(L);
	int errors_idx = lua_gettop(L);

	struct cv_ctx ctx;
	memset(&ctx, 0, sizeof(ctx));
	ctx.validate_only = validate_only;
	ctx.fail_fast     = false;
	ctx.depth         = 0;
	ctx.errors_idx    = errors_idx;

	bool ok = cv_check_node(L, &ctx, 2, *pp);

	int nerrors = (int)lua_objlen(L, errors_idx);
	bool success = ok && nerrors == 0;

	if (!success && raise_errors) {
		lua_rawgeti(L, errors_idx, 1);
		lua_getfield(L, -1, "message");
		lua_error(L);
	}

	/*
	 * Returns (data, errors):
	 *   data  = mutated value on success, nil on error
	 *   errors = array of error objects (empty on success)
	 */
	if (success)
		lua_pushvalue(L, 2);
	else
		lua_pushnil(L);
	lua_pushvalue(L, errors_idx);
	return 2;
}

/* =========================================================
 * cv.compile(def) -> schema, errors
 * ========================================================= */

static int
cv_compile(lua_State *L)
{
	/* arg 1: schema def
	 * arg 2: opts (optional) {raise_errors=bool} */
	bool raise_errors = false;
	if (lua_type(L, 2) == LUA_TTABLE) {
		lua_getfield(L, 2, "raise_errors");
		if (lua_isboolean(L, -1))
			raise_errors = lua_toboolean(L, -1);
		lua_pop(L, 1);
	}

	lua_newtable(L);
	int errors_idx = lua_gettop(L);

	bool oom = false;
	struct cv_node *n =
		cv_compile_node(L, 1, "$", errors_idx, &oom);

	if (oom) {
		lua_pushnil(L);
		lua_rawgeti(L, LUA_REGISTRYINDEX,
		            cv_oom_error_ref);
		return 2;
	}

	int nerrors = (int)lua_objlen(L, errors_idx);

	if (n == NULL || nerrors > 0) {
		if (n != NULL)
			cv_node_free(L, n);
		if (raise_errors) {
			lua_rawgeti(L, errors_idx, 1);
			lua_getfield(L, -1, "message");
			lua_error(L);
		}
		lua_pushnil(L);
		lua_pushvalue(L, errors_idx);
		return 2;
	}

	struct cv_node **pp =
		lua_newuserdata(L, sizeof(struct cv_node *));
	*pp = n;
	luaL_getmetatable(L, CV_NODE_MT);
	lua_setmetatable(L, -2);

	lua_pushnil(L);
	return 2;
}

/* =========================================================
 * cv._init(cfg) -- called from init.lua at load time
 * cfg = {
 *   uuid_is     = uuid.is_uuid,
 *   tuple_is    = box.tuple.is,
 *   ffi_typestr = function(v) return tostring(ffi.typeof(v)) end,
 * }
 * ========================================================= */

static int
cv__init(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);

	/* CTypeIDs — pure C, no Lua calls needed */
	cv_ctid_int64  = luaL_ctypeid(L, "int64_t");
	cv_ctid_uint64 = luaL_ctypeid(L, "uint64_t");

	/* uuid_is */
	if (cv_ref_uuid_is != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX,
		    cv_ref_uuid_is);
		cv_ref_uuid_is = LUA_NOREF;
	}
	lua_getfield(L, 1, "uuid_is");
	if (lua_isfunction(L, -1))
		cv_ref_uuid_is =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* tuple_is */
	if (cv_ref_tuple_is != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX,
		    cv_ref_tuple_is);
		cv_ref_tuple_is = LUA_NOREF;
	}
	lua_getfield(L, 1, "tuple_is");
	if (lua_isfunction(L, -1))
		cv_ref_tuple_is =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* ffi_typestr */
	if (cv_ref_ffi_typestr != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX,
		    cv_ref_ffi_typestr);
		cv_ref_ffi_typestr = LUA_NOREF;
	}
	lua_getfield(L, 1, "ffi_typestr");
	if (lua_isfunction(L, -1))
		cv_ref_ffi_typestr =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* box_null — cdata representing NULL */
	if (cv_ref_box_null != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX,
		    cv_ref_box_null);
		cv_ref_box_null = LUA_NOREF;
	}
	lua_getfield(L, 1, "box_null");
	if (!lua_isnil(L, -1))
		cv_ref_box_null =
			luaL_ref(L, LUA_REGISTRYINDEX);
	else
		lua_pop(L, 1);

	/* deepcopy function — required */
	if (cv_ref_deepcopy != LUA_NOREF) {
		luaL_unref(L, LUA_REGISTRYINDEX,
		    cv_ref_deepcopy);
		cv_ref_deepcopy = LUA_NOREF;
	}
	lua_getfield(L, 1, "deepcopy");
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 1);
		luaL_error(L,
		    "cv._init: deepcopy must be"
		    " a function");
	}
	cv_ref_deepcopy =
		luaL_ref(L, LUA_REGISTRYINDEX);

	return 0;
}

/* =========================================================
 * cv.is_schema(v) -> bool
 * ========================================================= */

static int
cv_is_schema(lua_State *L)
{
	bool r = (luaL_testudata(L, 1, CV_NODE_MT)
	          != NULL);
	lua_pushboolean(L, r);
	return 1;
}

/* =========================================================
 * Module init
 * ========================================================= */

LUA_API int
luaopen_cv_cvalidator(lua_State *L)
{
	/* pre-allocate OOM error object */
	lua_newtable(L);
	lua_newtable(L);
	lua_pushstring(L, "$");
	lua_setfield(L, -2, "path");
	lua_pushstring(L, "MEMORY_ERROR");
	lua_setfield(L, -2, "type");
	lua_pushstring(L, "Not enough memory");
	lua_setfield(L, -2, "message");
	lua_rawseti(L, -2, 1);
	cv_oom_error_ref =
		luaL_ref(L, LUA_REGISTRYINDEX);

	/* metatable for schema nodes */
	luaL_newmetatable(L, CV_NODE_MT);

	lua_pushcfunction(L, cv_node_gc);
	lua_setfield(L, -2, "__gc");

	lua_newtable(L);
	lua_pushcfunction(L, cv_schema_totable);
	lua_setfield(L, -2, "totable");
	lua_pushcfunction(L, cv_schema_check);
	lua_setfield(L, -2, "check");
	lua_setfield(L, -2, "__index");

	lua_pop(L, 1);

	/* module table */
	lua_newtable(L);
	lua_pushcfunction(L, cv_compile);
	lua_setfield(L, -2, "compile");
	lua_pushcfunction(L, cv__init);
	lua_setfield(L, -2, "_init");
	lua_pushcfunction(L, cv_is_schema);
	lua_setfield(L, -2, "is_schema");

	return 1;
}
// vim: syntax=c ts=8 sts=8 sw=8 noet
