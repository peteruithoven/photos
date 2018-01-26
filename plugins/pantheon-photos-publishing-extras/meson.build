publishing_extras_gresource = gnome.compile_resources('gresource_plugin_publishing_extras',
    'io.elementary.photos.plugins.publishing-extras.gresource.xml'
)

shared_module(
    'pantheon-photos-publishing-extras',
    'shotwell-publishing-extras.vala',
    'YandexPublishing.vala',
    'TumblrPublishing.vala',
    'Resources.vala',
    'RESTSupport.vala',
    publishing_extras_gresource,
    dependencies: elementary_photos_dep,
    install: true,
    install_dir: pluginsdir
)

