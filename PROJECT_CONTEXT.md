# cv - LuaC валидатор для Tarantool с совместимостью OpenAPI

## Цель проекта

Создать быстрый LuaC валидатор для Tarantool с поддержкой OpenAPI.

## Текущий статус

### Реализовано (работает):
- `cv.compile(def)` - парсит схему в C структуру `cv_node`
- `schema:totable()` - сериализует обратно в Lua таблицу
- `schema:totable('openapi')` - вывод в формате OpenAPI 3.1
- Скалярные типы: string, number, integer, unsigned, boolean, null, nil, uuid, tuple, function
- Составные типы: map (с properties/items), array (с items)
- oneof: `{type='oneof', variants={...}}` и `{oneOf={...}}`
- nullable через массив типов: `{type={'string', true}}`
- required для maps
- rename хранится в C структуре с сортировкой

### Ключевые файлы:
- `/home/unera/work/tnt/aeon/cv/cv/cv.c` - основная C реализация (~1400 строк)
- `/home/unera/work/tnt/aeon/cv/cv/CMakeLists.txt` - конфиг сборки
- `/home/unera/work/tnt/aeon/cv/test/compile_test.lua` - 44 теста

### Тесты: 44 теста проходят

## Обсуждение алгоритма cv_check

Мы проектировали алгоритм валидации. Пользователь предложил элегантное решение для rename:

Вместо того чтобы делать rename ДО валидации (что усложняет two-pass валидацию oneof),
делаем это на этапе компиляции:
- При компиляции map properties проверяем, есть ли у свойства rename alias
- Храним aliases в `props[i].aliases` массиве
- При итерации валидации проверяем И оригинальный ключ, И aliased ключи

Это позволяет "чистой валидации без мутаций" (validate_only/dry_run) работать корректно для oneof.

## Предложенный алгоритм map валидации:

```
1. Итерируемся по props (НЕ по data!)
   - Для каждого prop проверяем есть ли ключ в data
   - Если не найден, проверяем есть ли alias в data
   - Если найден через alias, валидируем это значение
   - Если опциональный с default и отсутствует, применяем default (если !validate_only)
2. Проверяем на неожиданные ключи (если !skip_unexpected)
   - если return_unexpected: оставляем в объекте
   - если skip_unexpected: удаляем из объекта
   - иначе: ошибка
3. transform (если !validate_only && нет ошибок)
```

Вопрос про rename когда и `from` и `to` присутствуют в data: предложение - не выдавать ошибку, оставить как есть (пользователь уже предоставил правильный вариант).

## Следующие шаги

Реализовать `cv_check(data, options)`:

1. Создать `struct cv_ctx` с флагом validate_only, массивом path, depth
2. Реализовать скалярную валидацию (проверка типа, constraint, default, transform)
3. Реализовать map валидацию с новым подходом на основе aliases
4. Реализовать array валидацию
5. Реализовать oneof (single-pass, как в старом валидаторе)
6. Добавить тесты

## Структура cv_node (текущая)

```c
struct cv_node {
    enum cv_type type;           // scalar, map, array, oneof
    enum cv_scalar scalar;       // string, number, etc если scalar
    struct cv_node **variants;   // для oneof
    int variants_count;
    
    // map
    struct cv_prop *props;
    int props_count;
    
    // array  
    struct cv_node *items;
    
    // constraints
    int min_length;
    int max_length;
    double minimum;
    double maximum;
    int max_items;
    int min_items;
    char *pattern;       // regex
    
    // rename
    struct cv_rename *renames;
    int renames_count;
    
    // meta
    char *default_value;
    char *transform;
};
```

## Команда для сборки

```bash
cd /home/unera/work/tnt/aeon/cv
cmake -B build && cmake --build build
ctest --test-dir build
```

## Запуск тестов

```bash
cd /home/unera/work/tnt/aeon/cv
lua test/compile_test.lua
```


### Последнее сообщение от пользователя

#### ИИ
Итого алгоритм валидации map:

Входные данные: t (Lua-таблица), n (cv_node MAP), ctx

1. rename (if !validate_only)

for each (from → to) in n.rename:
    if t[from] ~= nil:
        t[to] = t[from]
        t[from] = nil
2. итерация по схеме (props)

for each props[i] in n.props:
    val = t[props[i].key]
    if val == nil:
        if props[i].optional → skip
        elif props[i].default exists and !validate_only:
            t[key] = default
        else → MISSING_FIELD error
    else:
        cv_check_node(val, props[i].node, ctx)
3. проверка лишних ключей (if !skip_unexpected)

вариант A !skip_unexpected:
итерируем по t, ключ не найден в props → UNEXPECTED_FIELD error
вариант B skip_unexpected && !return_unexpected:
итерируем по t, собираем лишние ключи на Lua-стек
после итерации удаляем: t[key] = nil
вариант C skip_unexpected && return_unexpected:
ничего не делаем
4. transform (if !validate_only && no errors)

call n.transform(t)
Ничего не забыли?
Итого алгоритм валидации map:

Входные данные: t (Lua-таблица), n (cv_node MAP), ctx

1. rename (if !validate_only)

for each (from → to) in n.rename:
    if t[from] ~= nil:
        t[to] = t[from]
        t[from] = nil
2. итерация по схеме (props)

for each props[i] in n.props:
    val = t[props[i].key]
    if val == nil:
        if props[i].optional → skip
        elif props[i].default exists and !validate_only:
            t[key] = default
        else → MISSING_FIELD error
    else:
        cv_check_node(val, props[i].node, ctx)
3. проверка лишних ключей (if !skip_unexpected)

вариант A !skip_unexpected:
итерируем по t, ключ не найден в props → UNEXPECTED_FIELD error
вариант B skip_unexpected && !return_unexpected:
итерируем по t, собираем лишние ключи на Lua-стек
после итерации удаляем: t[key] = nil
вариант C skip_unexpected && return_unexpected:
ничего не делаем
4. transform (if !validate_only && no errors)

call n.transform(t)
Ничего не забыли?

#### Пользователь

а пункт 1 в старом так же сделан? выглядит логично. но что если и from и to заполнены? бросать ли здесь ошибку или оставлять именно так? Хгм

2 выглядит верно


3,4 тоже ок.


остаётся придумать что же делать с rename. можем ли мы его перенести на ПОСЛЕ валидации.


что если rename при компиляции проставит тем пропсам В которые он rename делает алиасы имён?


например


rename [1] = 'to'


тогда найдёт props['to'].aliases и пушнет туда 1
если props['to'] нет - ничего не сделает.


тогда при итерации по props, если мы не нашли нужный элемент в data, мы можем посмотреть а есть ли он в неперименованном виде. и если есть - прочекать его.


тогда мы действительно можем сделать чистую проверку с выключенной мутабельностью. (при проставлении default проверку не проводить ибо считаем, что default человек не дурак - правильно пишет). Ну или default тоже проверять, но так как и с rename.

