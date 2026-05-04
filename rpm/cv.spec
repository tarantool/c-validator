Name: cv
Version: 1.0.0
Release: 1%{?dist}
Summary: Fast OpenAPI 3.1 Compatible Schema Validator for Tarantool
Group: Applications/Databases
License: BSD
URL: https://github.com/tarantool/c-validator
Source0: %{name}-%{version}.tar.gz
BuildRequires: cmake >= 3.5
BuildRequires: gcc >= 13.2.1
BuildRequires: tarantool-devel >= 3.7.0
Requires: tarantool >= 3.7.0

%description
Fast OpenAPI 3.1 Compatible Schema Validator for Tarantool.

%prep
%setup -q -n %{name}-%{version}

%build
%cmake
%cmake_build

%install
%cmake_install

%files
%{_libdir}/tarantool/*/
%{_datadir}/tarantool/*/
%doc README.md
%{!?_licensedir:%global license %doc}
%license LICENSE AUTHORS

%changelog
* Mon May 4 2026 Mergen Imeev <imeevma@gmail.com> 1.0.0-1
- Initial version of the RPM spec
