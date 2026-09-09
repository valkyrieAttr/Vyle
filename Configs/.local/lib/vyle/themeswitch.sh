#!/usr/bin/env bash
set -eo pipefail

scrDir="$(dirname "$(realpath "$0")")"
source "${scrDir}/globalcontrol.sh"

lockFile="${XDG_RUNTIME_DIR}/${0##*/}.lock"
if [ -e "${lockFile}" ]; then
    cat <<EOF
Error: Another instance of ${0##*/} is running.
If you are sure that no other instance of ${0##*/} running, then remove the lock file:
    $lockFile
EOF
    notify-send -a "t2" -r 91190 -t 800 -i "${dunstDir}/icons/hyprdots.svg" "Vyle" "Another instance of ${0##*/} is running."
    exit 0
fi

touch "${lockFile}"
trap 'rm -f ${lockFile}' EXIT

show_theme_status() {
    cat <<EOF
Current theme: $VYLE_RESERVED_THEME
Cursor theme: $HYPRLAND_CURSOR_THEME
Cursor size: $HYPRLAND_CURSOR_SIZE
Terminal: $HYPRLAND_TERMINAL
Font: $GTK_FONT_NAME
Font size: $GTK_FONT_SIZE
Document font: $GTK_DOCUMENT_FONT
Document font size: $GTK_DOCUMENT_FONT_SIZE
Monospace font: $GTK_MONOSPACE_FONT
Monospace font size: $GTK_MONOSPACE_FONT_SIZE

Selected theme: $thmChsh
Wallpaper: ${thmImg##*/}
Wallpaper Backend: $WALLPAPER_CONFIGURATION_BACKEND
Framerate: ${WALLPAPER_SWWW_FRAMERATE}
Duration: ${WALLPAPER_SWWW_TRANSITION_DURATION}
Bezier: ${WALLPAPER_SWWW_TRANSITION_BEZIER}
Animation: {
   Transition Previous: ${WALLPAPER_SWWW_ANIMATION_PREVIOUS}
   Transition Next: ${WALLPAPER_SWWW_ANIMATION_NEXT}
   Transition Theme: ${WALLPAPER_SWWW_ANIMATION_THEME}
}
Custom Paths: [${wallAddCustomPath}]

EOF
}

show_help_status() {
    cat <<EOF
Vyle-Project's Theme-Switcher Command-line.

Usage: 
  ${0##*/} [flags]

Available Flags:
  -n      Switch to the next theme.
  -p      Switch to the previous theme.
  -t      Requires an argument. 
                    Example: ${0##*/} -t Decay-Green
  -h      Help Menu
EOF
}

themeDir="${VYLE_CONFIG_HOME}/theme"
rofiConf="${rasiDir}/selector.rasi"

themeSelTui() {
    thmChsh="${1}"
    thmImg="$(<"${themeDir}/${thmChsh}/wallpapers/.wallbash-main")"
    if [[ -n "${thmImg}" ]]; then
        show_theme_status &
        if [[ "${VYLE_RESERVED_THEME}" != "${thmChsh}" ]]; then
            setConf "VYLE_RESERVED_THEME" "${thmChsh}" "${VYLE_STATE_HOME}/staterc"
        fi
        if [[ "${VYLE_WALLPAPER_DIRECTORY}" != "${themeDir}/${thmChsh}/wallpapers" ]]; then
            echo "Theme Control - Theme '${thmChsh}' :: Wallpaper '${thmImg}' :: DcolMode '${WALLBASH_MODE}' --> '${XDG_CONFIG_HOME}'"
            THEME_IMAGE_NO_EXTN="${thmImg##*/}"
            THEME_IMAGE_NO_EXTN="${THEME_IMAGE_NO_EXTN%.*}"
            notify -m 2 -i "theme_engine" -p "${thmChsh}" -s "${VYLE_CACHE_HOME}/thmb/${THEME_IMAGE_NO_EXTN}.thmb" -t 1100 -a "t1"
            setConf "VYLE_WALLPAPER_DIRECTORY" "${themeDir}/${thmChsh}/wallpapers" "${VYLE_STATE_HOME}/staterc"
        else
            echo -e "Theme Control - Skipped populating $thmChsh -> ${XDG_CONFIG_HOME}"
            exit 0
        fi
        if [[ "${WALLBASH_MODE}" -eq 3 ]]; then
            if [[ "${VYLE_THEME}" != "${thmChsh}" ]]; then
                setConf "VYLE_THEME" "${thmChsh}" "${VYLE_STATE_HOME}/staterc"
            fi
            sed -i 's|^[[:space:]]*source[[:space:]]*=[[:space:]]* \$XDG_CONFIG_HOME/hypr/themes/wallbash.conf|#source = \$XDG_CONFIG_HOME/hypr/themes/wallbash.conf|' "${VYLE_DATA_HOME}/hypr/dynamic.conf"
        else
            "${scrDir}/hyir.sh" \
                --file "${themeDir}/${thmChsh}/hypr.theme" \
                --proc "${VYLE_CONFIGURATION_CORE}" \
                --no-atomic \
                --defer-run \
                --run-concurrency 0 \
                --disable-fallback \
                --ignore-unbound

            sed -i 's|^#[[:space:]]*source[[:space:]]*=[[:space:]]* \$XDG_CONFIG_HOME/hypr/themes/wallbash.conf|source = \$XDG_CONFIG_HOME/hypr/themes/wallbash.conf|' "${VYLE_DATA_HOME}/hypr/dynamic.conf"
        fi
        [[ ! -e "${scrDir}/swwwallswitch.sh" ]] && {
            notify -m 1 -p "Does swwwallswitch.sh exist?" -s "${dunstDir}/icons/hyprdots.svg" -u critical
            return 1
        }
        "${scrDir}/swwwallswitch.sh" -t -i "${thmImg}" -w --swww-t -n
        echo -e "Theme Control - Populated successfully ${thmChsh} -> ${XDG_CONFIG_HOME}" &
    fi
}

thmSelEnv() {
    if [[ -z "${ROFI_THEME_SCALE}" || "${ROFI_THEME_SCALE}" -eq 0 ]]; then
        ROFI_THEME_SCALE=10
    fi
    r_scale="configuration {font : \"${ROFI_THEME_FONT} ${ROFI_THEME_SCALE}\";}"
    mon_x_res=$((mon_res * 100 / mon_scale))
    elem_border=$((hypr_border * 3))
    icon_border=$((elem_border - 5))

    case "${ROFI_THEME_STYLE:-1}" in
    2)
        elm_width=$(((20 + 12) * ROFI_THEME_SCALE * 2))
        max_avail=$((mon_x_res - (4 * ROFI_THEME_SCALE)))
        if [[ -z "$ROFI_THEME_COLUMN" || ! "$ROFI_THEME_COLUMN" =~ ^[0-9]+$ || "$ROFI_THEME_COLUMN" -eq 0 ]]; then
            ROFI_THEME_COLUMN=$((max_avail / elm_width))
        fi
        r_override="window{width:100%;background-color:#00000003;} 
                listview{columns:${ROFI_THEME_COLUMN};} 
                element{border-radius:${elem_border}px;background-color:@main-bg;}
                element-icon{size:20em;border-radius:${icon_border}px 0px 0px ${icon_border}px;}"
        thmExtn="quad"
        ;;
    1 | *)
        elm_width=$(((23 + 12 + 1) * ROFI_THEME_SCALE * 2))
        max_avail=$((mon_x_res - (4 * ROFI_THEME_SCALE)))
        if [[ -z "$ROFI_THEME_COLUMN" || ! "$ROFI_THEME_COLUMN" =~ ^[0-9]+$ || "$ROFI_THEME_COLUMN" -eq 0 ]]; then
            ROFI_THEME_COLUMN=$((max_avail / elm_width))
        fi
        r_override="window{width:100%;}
                listview{columns:${ROFI_THEME_COLUMN};}
                element{border-radius:${elem_border}px;padding:0.5em;}
                element-icon{size:23em;border-radius:${icon_border}px;}"
        thmExtn="thmb"
        ;;
    esac

    thumbDir="${VYLE_CACHE_HOME}/${thmExtn}"
    mapfile -t themes < <(LC_ALL=C find "${themeDir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -Vf)
    choice=$(
        for indx in "${themes[@]}"; do
            VYLE_CURRENT_IMAGE="${themeDir}/${indx}/wall.set"
            if [ ! -e "${themeDir}/${indx}/wallpapers/.wallbash-main" ]; then
                thmWall="$(find "${themeDir}/${indx}/wallpapers" -type f ! -name '.*' | sort -V | head -n 1 | tee -a "${themeDir}/${indx}/wallpapers/.wallbash-main")"
            else
                thmWall="$(<"${themeDir}/${indx}/wallpapers/.wallbash-main")"
            fi

            thmWall="${thmWall##*/}"
            thmWall="${thmWall%.*}.${thmExtn}"

            relpath="$(readlink -f "${VYLE_CURRENT_IMAGE}" 2>/dev/null || true)"
            stripPath="${relpath##*.}"

            if [[ ! -L "${VYLE_CURRENT_IMAGE}" || -L "${VYLE_CURRENT_IMAGE}" && ! -e "${VYLE_CURRENT_IMAGE}" || "${stripPath}" != "${thmExtn}" || -z "${relpath}" ]]; then
                echo -e " :: fixing symlink - ${thumbDir}/${thmWall} -> ${VYLE_CURRENT_IMAGE}" >&2
                ln -fs "${thumbDir}/${thmWall}" "${VYLE_CURRENT_IMAGE}"
            fi
            printf "%s\x00icon\x1f%s\n" "${indx}" "${VYLE_CURRENT_IMAGE}"
        done | rofi -dmenu -i -p "ThemeControl" -theme-str "${r_scale}" -theme-str "${r_override}" -config "${rofiConf}" -select "${VYLE_RESERVED_THEME}"
    )

    [[ -z "$choice" ]] && exit 0
    sleep 0.7
    themeSelTui "$choice"
}

theme_control() {
    mapfile -t themes < <(LC_ALL=C find "${themeDir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -Vf)

    for i in "${!themes[@]}"; do
        if [[ "${themes[$i]}" == "$VYLE_RESERVED_THEME" ]]; then
            if [ "$1" == "-n" ]; then
                setIdx=$((($i + 1) % ${#themes[@]}))
            elif [ "$1" == "-p" ]; then
                setIdx=$((($i - 1 + ${#themes[@]}) % ${#themes[@]}))
            else
                return 1
            fi
            break
        fi
    done
    themeSelTui "${themes[$setIdx]}"
}

case "${1}" in
-n | -p)
    theme_control "$1"
    ;;
-t | -tui)
    themeSelTui "$2"
    ;;
-h | --help)
    show_help_status
    ;;
* | --select)
    thmSelEnv
    ;;
esac
