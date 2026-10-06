project('singularity-store', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-store"', language: 'c')
subdir('po')

gnome = import('gnome')
cc    = meson.get_compiler('c')

gtk_dep      = dependency('gtk4')
gee_dep      = dependency('gee-0.8')
soup_dep     = dependency('libsoup-3.0')
json_dep     = dependency('json-glib-1.0')
gio_unix_dep = dependency('gio-unix-2.0')
math_dep     = cc.find_library('m')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

subdir('ui')

resources = gnome.compile_resources(
  'singularity-store-resources',
  'resources/dev.sinty.store.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: main_ui
)

sources = files(
  'src/app_info.vala',
  'src/window.vala',
  'src/app.vala',
  'src/update_badge.vala',
  'src/search_provider.vala',
  'src/main.vala',
)

executable('singularity-store',
  sources + [resources],
  dependencies: [gtk_dep, gee_dep, soup_dep, json_dep, gio_unix_dep, math_dep, libsingularity_dep],
  vala_args: ['--pkg=gio-unix-2.0'],
  install: true
)

executable('singularity-store-updates',
  files('src/update_badge.vala', 'src/update_checker.vala'),
  dependencies: [dependency('gio-2.0')],
  install: true
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.store.service.in',
  output: 'dev.sinty.store.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)
configure_file(
  input: 'data/dev.sinty.store.Updates.service.in',
  output: 'dev.sinty.store.Updates.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)
install_data('data/dev.sinty.store.search-provider.ini',
  rename: 'dev.sinty.store.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

install_data('data/dev.sinty.store.updates.desktop',
  install_dir: get_option('sysconfdir') / 'xdg' / 'autostart'
)

install_data('data/dev.sinty.store.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.store.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/icons/dev.sinty.store.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
