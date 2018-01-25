# Photos
[![Translation status](https://l10n.elementary.io/widgets/photos/-/svg-badge.svg)](https://l10n.elementary.io/projects/photos/?utm_source=widget)

## Building, Testing, and Installation

You'll need the following dependencies:
* meson
* desktop-file-utils
* intltool
* libaccounts-glib-dev
* libexif-dev
* libgee-0.8-dev
* libgeocode-glib-dev
* libgexiv2-dev
* libglib2.0-dev
* libgphoto2-dev
* libgranite-dev
* libgstreamer1.0-dev
* libgstreamer-plugins-base1.0-dev
* libgtk-3-dev
* libgudev-1.0-dev
* libjson-glib-dev
* libraw-dev
* librest-dev
* libsignon-glib-dev
* libsoup2.4-dev
* libsqlite3-dev
* libunity-dev
* libwebkit2gtk-4.0-dev
* libwebp-dev
* libxml2
* python-scour
* valac

Run `meson build` to configure the build environment. Change to the build directory and run `ninja test` to build

    meson build --prefix=/usr
    cd build

To install, use `ninja install`, then execute with `pantheon-photos`

    sudo ninja install
    pantheon-photos
