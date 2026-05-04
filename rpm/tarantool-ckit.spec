Name: cv
Version: 1.0.0
Release: 1%{?dist}
Summary: Fast OpenAPI 3.1 Compatible Schema Validator for Tarantool
Group: Applications/Databases
License: BSD
URL: https://github.com/tarantool/c-validator
Source0: %{name}-%{version}.tar.gz
BuildRequires: cmake >= 2.8
BuildRequires: gcc >= 4.5
Requires: tarantool >= 1.6.8.0

%description
Fast OpenAPI 3.1 Compatible Schema Validator for Tarantool.

%prep
%setup -q -n %{name}-%{version}

%build
mkdir -p build
cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=%{_lib}
#%cmake
#%cmake_build

%install
make -C build install DESTDIR=%{buildroot}

%files
%{_libdir}/tarantool/*/
%{_datarootdir}/tarantool/*/

%changelog
* Mon Feb 27 2017 Roman Tsisyk <roman@tarantool.org> 2.0.0-1
- Split package into luakit and ckit.

* Wed Feb 17 2016 Roman Tsisyk <roman@tarantool.org> 1.0.1-1
- Fix to comply Fedora Package Guidelines

* Wed Sep 16 2015 Roman Tsisyk <roman@tarantool.org> 1.0.0-1
- Initial version of the RPM spec
