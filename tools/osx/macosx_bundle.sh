#!/bin/bash

# Required variables
# ------------------
# these are very important variables. Must be set into rtdata/CMakeLists.txt!
# - PROJECT_NAME
# - PROJECT_SOURCE_DIR
# - PROJECT_VERSION (if without git)
# - CMAKE_BUILD_TYPE
# - PROC_BIT_DEPTH
# - GTK_PREFIX

function message {
    printf '\e[34m-- %s\e[m\n' "$*"
}

function GetDependencies {
    otool -L "$1" | awk 'NR >= 2 && $1 !~ /^(\/usr\/lib|\/System|@executable_path|@rpath)\// { print $1 }'
}

function CheckLink {
    GetDependencies "$1" | while read; do
        local dest="${LIB}/$(basename "${REPLY}")"
        test -f "${dest}" || { ditto --arch ${arch} "${REPLY}" "${dest}"; CheckLink "${dest}"; }
    done
}

# source check
if test ! -d "${CMAKE_BUILD_TYPE}"; then
    printf "\e[31m${PWD}/${CMAKE_BUILD_TYPE} directory is not found. Please execute 'make install' first.\e[m\n"
    exit 1
fi

# update project version
if test -x "$(which git)" -a -d "${PROJECT_SOURCE_DIR}/.git"; then
    # This is what the version ought to look like to be accurate in the git universe:
    PROJECT_FULL_VERSION="$(git describe --tags --always | sed 's/-g.*//')_$(git symbolic-ref --short -q HEAD)"
    # outputs: 4.2-677-g904467b_master
    # but Apple requirements https://goo.gl/eWDQv6 state we should use this:
    PROJECT_VERSION="$(git describe --tags --always | sed -e 's/-g.*//' -e 's/-/./')"
    # outputs: 4.2.677
fi

# if not specify CMAKE_OSX_DEPLOYMENT_TARGET when compiling,
# 'MINIMUM_VERSION' will be used host OS X version.
MINIMUM_SYSTEM_VERSION="$(otool -l "${CMAKE_BUILD_TYPE}"/rawtherapee | grep -A2 'LC_VERSION_MIN_MACOSX' | awk '$1 ~ /version/ { printf $2 }')"
if test ! -n "${MINIMUM_SYSTEM_VERSION}"; then
    MINIMUM_SYSTEM_VERSION="$(sw_vers -productVersion | cut -d. -f-2)"
fi

# check for pango-querymodules. Pango 1.38.0 and above do not include it.
# https://github.com/Homebrew/homebrew/issues/44764#issuecomment-146795820
PangoVer="$(brew list --versions pango)"
PangoVer="${PangoVer//./}"
# Only check the first 4 digits, so that "1.36.99" (13699) doesn't test greater than "1.38.0" (1380)
PangoVer="${PangoVer:0:4}"
if [[ "$PangoVer" -ge "1380" ]]; then
    ExistPangoQuerymodules="false"
else
    ExistPangoQuerymodules="true"
fi

case ${PROC_BIT_DEPTH} in
    64) arch=x86_64;;
    32) arch=i386;;
esac

cat <<__EOS__
PROJECT_NAME:           ${PROJECT_NAME}
PROJECT_VERSION:        ${PROJECT_VERSION}
PROJECT_SOURCE_DIR:     ${PROJECT_SOURCE_DIR}
CMAKE_BUILD_TYPE:       ${CMAKE_BUILD_TYPE}
PROC_BIT_DEPTH:         ${PROC_BIT_DEPTH}
MINIMUM_SYSTEM_VERSION: ${MINIMUM_SYSTEM_VERSION}
GTK_PREFIX:             ${GTK_PREFIX}
PWD:                    ${PWD}
__EOS__

APP="${PROJECT_NAME}".app
CONTENTS="${APP}"/Contents
RESOURCES="${CONTENTS}"/Resources
MACOS="${CONTENTS}"/MacOS
LIB="${MACOS}"/lib
ETC="${MACOS}"/etc
EXECUTABLE="${MACOS}"/rawtherapee

message "Removing old files"
rm -rf "${APP}" ${PROJECT_NAME}_*.dmg

message "Creating bundle container"
install -d  "${RESOURCES}" \
"${MACOS}" \
"${LIB}" \
"${ETC}"

message "Copying release files"
ditto "${CMAKE_BUILD_TYPE}" "${MACOS}"

message "Copying dependencies from ${GTK_PREFIX}"
CheckLink "${EXECUTABLE}"

message "Copying library modules from ${GTK_PREFIX}"
ditto --arch "${arch}" {"${GTK_PREFIX}"/lib,"${LIB}"}/gdk-pixbuf-2.0
ditto --arch "${arch}" {"${GTK_PREFIX}"/lib,"${LIB}"}/gtk-2.0
ditto --arch "${arch}" {"${GTK_PREFIX}"/lib,"${LIB}"}/pango

message "Removing static libraries and cache files"
find -E "${LIB}" -type f -regex '.*\.(a|la|cache)$' | while read; do rm "${REPLY}"; done

message "Copying configuration files from ${GTK_PREFIX}"
install -d "${ETC}"/{gtk-2.0,pango}
cp "${GTK_PREFIX}"/etc/gtk-2.0/im-multipress.conf "${ETC}"/gtk-2.0
"${GTK_PREFIX}"/bin/gdk-pixbuf-query-loaders "${LIB}"/gdk-pixbuf-2.0/*/loaders/*.so > "${ETC}"/gtk-2.0/gdk-pixbuf.loaders
"${GTK_PREFIX}"/bin/gtk-query-immodules-2.0  "${LIB}"/gtk-2.0/*/immodules/*.so      > "${ETC}"/gtk-2.0/gtk.immodules
sed -i "" -e "s|${PWD}|/tmp|" "${ETC}"/gtk-2.0/gdk-pixbuf.loaders \
"${ETC}"/gtk-2.0/gtk.immodules
if [[ "$ExistPangoQuerymodules" = "true" ]]; then
    "${GTK_PREFIX}"/bin/pango-querymodules       "${LIB}"/pango/*/modules/*.so          > "${ETC}"/pango/pango.modules
    sed -i "" -e "s|${PWD}|/tmp|" "${ETC}"/pango/pango.modules
    printf "[Pango]\nModuleFiles = /tmp/${ETC}/pango/pango.modules" > "${ETC}"/pango/pangorc
fi

message "Copying shared files from ${GTK_PREFIX}"
cp -R "${GTK_PREFIX}"/share/mime "${MACOS}"/share
# gtk themes
ditto {"${GTK_PREFIX}","${MACOS}"}/share/themes/Mac/gtk-2.0-key/gtkrc
ditto {"${GTK_PREFIX}","${MACOS}"}/share/themes/Clearlooks/gtk-2.0/gtkrc
install -d "${MACOS}"/share/themes/Raleigh/gtk-2.0
(cd "${MACOS}"/share/themes/Raleigh/gtk-2.0 && ln -s ../../Clearlooks/gtk-2.0/gtkrc)
# fontconfig files (X11 backend only)
if otool -L "${EXECUTABLE}" | grep -sq 'libgtk-x11-2.0'; then
    message "Installing fontconfig files (Your library is X11 backend. 'FONTCONFIG_PATH' will be set by executable loader.)"
    cp -RL "${GTK_PREFIX}"/etc/fonts "${ETC}"
fi



# install names
find -E "${MACOS}" -type f -regex '.*/(rawtherapee|.*\.(dylib|so))' | while read x; do
    message "Modifying install names: ${x}"
    {
        # id
    case ${x} in *.dylib) echo "   install_name_tool -id '@rpath/$(basename "${x}")' '${x}'";; esac
    # names
    GetDependencies "${x}" | while read y; do
        echo "   install_name_tool -change '${y}' '@rpath/$(basename "${y}")' '${x}'"
    done
} | bash -v
done

message "Registering @loader_path into the executable"
echo "   install_name_tool -add_rpath @loader_path/lib '${EXECUTABLE}'" | bash -v



message "Installing required application bundle files"
PROJECT_SOURCE_DATA_DIR="${PROJECT_SOURCE_DIR}"/tools/osx
# executable loader
# note: executable is renamed to 'rawtherapee-bin'.
mv "${MACOS}"/rawtherapee{,-bin}
install -m 0755 "${PROJECT_SOURCE_DATA_DIR}"/executable_loader.in "${MACOS}"/rawtherapee
# app bundle resources
cp "${PROJECT_SOURCE_DATA_DIR}"/{rawtherapee,profile}.icns "${RESOURCES}"
cp "${PROJECT_SOURCE_DATA_DIR}"/PkgInfo "${CONTENTS}"
install -m 0644 "${PROJECT_SOURCE_DATA_DIR}"/Info.plist.in "${CONTENTS}"/Info.plist
sed -i "" -e "s|@version@|${PROJECT_VERSION}|
s|@shortVersion@|${PROJECT_VERSION}|
s|@arch@|${arch}|" \
"${CONTENTS}"/Info.plist
plutil -convert binary1 "${CONTENTS}"/Info.plist



function CreateDmg {
    local srcdir="$(mktemp -dt $$)"

    message "Preparing disk image sources at ${srcdir}"
    mv "${APP}" "${srcdir}"
    cp AboutThisBuild.txt "${srcdir}"
    ln -s /Applications "${srcdir}"

    # web bookmarks
    function CreateWebloc {
        defaults write "${srcdir}/$1" URL "$2"
        mv "${srcdir}/$1".{plist,webloc}
    }
    CreateWebloc 'RawTherapee Blog' 'http://www.rawtherapee.com'
    CreateWebloc 'Online Manual'    'http://rawpedia.rawtherapee.com/'

    # disk image name
    dmg_name="${PROJECT_NAME// /_}_OSX_${MINIMUM_SYSTEM_VERSION}_${PROC_BIT_DEPTH}_${PROJECT_FULL_VERSION}"
    if ! echo "${CMAKE_BUILD_TYPE}" | grep -sqi "release"; then
        dmg_name="${dmg_name}_$(echo ${CMAKE_BUILD_TYPE} | tr '[:upper:]' '[:lower:]')"
    fi

    message "Creating disk image"
    hdiutil create -format UDBZ -srcdir "${srcdir}" -volname "${PROJECT_NAME}_${PROJECT_FULL_VERSION}" "${dmg_name}".dmg

    message "Removing disk image caches"
    rm -rf "${srcdir}"
}
CreateDmg
