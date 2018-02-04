global_gresource = gnome.compile_resources('gresource_global', 'io.elementary.photos.gresource.xml')

install_data(
    'org.pantheon.photos-extras.gschema.xml',
    'org.pantheon.photos.gschema.xml',
    install_dir: join_paths(get_option('prefix'), get_option('datadir'), 'glib-2.0', 'schemas')
)

config_data = configuration_data()
config_data.set('EXEC_NAME', meson.project_name())

# Set the executable name and translate the desktop files
viewer_desktop_in_file = configure_file(
    input: 'org.pantheon.photos-viewer.desktop.in.in',
    output: '@BASENAME@',
    configuration: config_data
)

viewer_desktop_file = i18n.merge_file(
    input: viewer_desktop_in_file,
    output: 'org.pantheon.photos-viewer.desktop',
    po_dir: join_paths(meson.source_root (), 'po', 'extra'),
    type: 'desktop',
    install_dir: join_paths(get_option('datadir'), 'applications'),
    install: true
)

app_desktop_in_file = configure_file(
    input: 'org.pantheon.photos.desktop.in.in',
    output: '@BASENAME@',
    configuration: config_data
)

app_desktop_file = i18n.merge_file(
    input: app_desktop_in_file,
    output: 'org.pantheon.photos.desktop',
    po_dir: join_paths(meson.source_root (), 'po', 'extra'),
    type: 'desktop',
    install_dir: join_paths(get_option('datadir'), 'applications'),
    install: true
)

# Translate the AppData file
appstream_file = i18n.merge_file(
    input: 'io.elementary.photos.appdata.xml.in',
    output: '@BASENAME@',
    po_dir: join_paths(meson.source_root (), 'po', 'extra'),
    install_dir: join_paths(get_option('datadir'), 'metainfo'),
    install: true
)

# Test the Desktop files
validate_desktop_exe = find_program('desktop-file-validate')
test ('Validate Desktop file', validate_desktop_exe,
    args: app_desktop_file
)

test ('Validate Viewer Desktop file', validate_desktop_exe,
    args: viewer_desktop_file
)

# Test the AppData file
appstreamcli_exe = find_program('appstreamcli')

test ('Validate AppStream file', appstreamcli_exe,
    args: [
        'validate',
        appstream_file
    ]
)

subdir('icons')
