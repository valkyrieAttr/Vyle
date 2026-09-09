#!/usr/bin/env bash
set -eo pipefail

scrDir=$(dirname "$(realpath "$0")")
source "$scrDir/globalcontrol.sh"

lock_File="${XDG_RUNTIME_DIR}/${BASH_SOURCE[0]##*/}.lock"
if [[ -e "${lock_File}" ]]; then
    cat <<EOF
Error: Another instance of ${BASH_SOURCE[0]##*/} is running. 
If you are sure that no other instance is running. Remove the the lock file:
    $lock_File
EOF
    notify-send -a "t2" -r 91190 -t 800 -i "${dunstDir}/icons/hyprdots.svg" "Vyle" "Another instance of ${BASH_SOURCE[0]##*/} is running."
    exit 0
fi
touch "${lock_File}"
trap 'rm -f ${lock_File}' EXIT

wallSel="${VYLE_WALLPAPER_DIRECTORY}"
dcolDir="${VYLE_CACHE_HOME}/shell"
blurDir="${VYLE_CACHE_HOME}/blur"
colsDir="${VYLE_CACHE_HOME}/cols"
thumbDir="${VYLE_CACHE_HOME}/thmb"
quadDir="${VYLE_CACHE_HOME}/quad"
rofiConf="${rasiDir}/selector.rasi"

[[ -d "${VYLE_CACHE_HOME}" ]] || mkdir -p "${VYLE_CACHE_HOME}"
[[ -d "${blurDir}" ]] || mkdir -p "${blurDir}"
[[ -d "${colsDir}" ]] || mkdir -p "${colsDir}"
[[ -d "${thumbDir}" ]] || mkdir -p "${thumbDir}"

help_function() {
    cat <<EOF
Vyle-Project: ${0##*/} command-line wallpaper handler.
Usage:
  ${0##*/} [flags]
Available Flags:
  -n | --next     Switch to the next wallpaper
  -p | --prev     Switch to the previous wallpaper
  -t | --multi-select   Use other flags
  -r | --random   Switch to a random wallpaper
  -h | --help     ${0##*/} executes --help
Tips: 
  Use ${0##*/} [flag] --help for more information about a command/flag.
EOF
}

Wall_Change() {
    mapfile -t wallpapers < <(LC_ALL=C find "${VYLE_WALLPAPER_DIRECTORY}" -maxdepth 1 -mindepth 1 -type f ! -name '.*' -printf '%f\n' | sort -V)

    for indx in "${!wallpapers[@]}"; do
        if [[ "${wallpapers[$indx]}" == "${VYLE_CURRENT_IMAGE##*/}" ]]; then
            if [ "$1" == "-n" ]; then
                setIdx=$(((indx + 1) % ${#wallpapers[@]}))
                swwwTrans="-n"
            elif [ "$1" == "-p" ]; then
                setIdx=$(((indx - 1 + ${#wallpapers[@]}) % ${#wallpapers[@]}))
                swwwTrans="-p"
            else
                echo "No argument has been passed!"
                exit 1
            fi
            break
        fi
    done

    Wall_Switch -i "${VYLE_WALLPAPER_DIRECTORY}/${wallpapers[setIdx]}" -w "${swwwTrans}" -n 1
}

SWWW_TRANSITION() {
    case "${WALLPAPER_SET_FLAGS}" in
    "--swww-p" | "--swww-t") ;;
    "--swww-n" | *) ;;
    esac
}

Wall_Initialize() {
    case "${ROFI_THEME_STYLE}" in
    2) thmExtn="quad" ;;
    1 | *) thmExtn="thmb" ;;
    esac

    echo "${VYLE_IMAGE_SOURCE}" >"${VYLE_CONFIG_HOME}/theme/${VYLE_RESERVED_THEME}/wallpapers/.wallbash-main"
    setConf "VYLE_CURRENT_IMAGE" "\${VYLE_CONFIG_HOME}/theme/\${VYLE_RESERVED_THEME}/wallpapers/${VYLE_IMAGE_SOURCE##*/}" "${VYLE_STATE_HOME}/staterc"
    ln -sf "${colsDir}/${VYLE_SOURCE_NO_EXTN}.cols" "${rasiDir}/wall.cols"
    ln -sf "${blurDir}/${VYLE_SOURCE_NO_EXTN}.bpex" "${rasiDir}/wall.bpex"
    ln -sf "${thumbDir}/${VYLE_SOURCE_NO_EXTN}.thmb" "${rasiDir}/wall.thmb"
    ln -sf "${quadDir}/${VYLE_SOURCE_NO_EXTN}.quad" "${rasiDir}/wall.quad"
    ln -sf "${cacheDir}/${thmExtn}/${VYLE_SOURCE_NO_EXTN}.${thmExtn}" "${VYLE_CONFIG_HOME}/theme/${VYLE_RESERVED_THEME}/wall.set"

    read -r hashMech <<<"$(md5sum "${VYLE_IMAGE_SOURCE}" | awk '{print $1}')"
}

Wall_Switch() {
    OPTIND=1
    local VYLE_IMAGE_SOURCE="" WALLPAPER_SET_FLAGS ntSend="" thmExtn
    while getopts ":i:w:n" arg; do
        case "${arg}" in
        i)
            VYLE_IMAGE_SOURCE="${OPTARG}"
            ;;
        w)
            WALLPAPER_SET_FLAGS="${OPTARG}"
            ;;
        n)
            ntSend=false
            ;;
        esac
    done
    shift $((OPTIND - 1))
    if [[ -z "${VYLE_IMAGE_SOURCE}" || ! -f "${VYLE_IMAGE_SOURCE}" ]]; then
        VYLE_IMAGE_SOURCE="${VYLE_CURRENT_IMAGE}"
        if [[ ! -f "${VYLE_IMAGE_SOURCE}" ]]; then
            notify -m 1 -p "Invalid wallpaper?" -u critical -t 900 -a "t1"
            exit 1
        fi
    fi

    VYLE_SOURCE_NO_EXTN="${VYLE_IMAGE_SOURCE##*/}"
    VYLE_SOURCE_NO_EXTN="${VYLE_SOURCE_NO_EXTN%.*}"
    Wall_Initialize

    $ntSend && notify -m 2 -i "theme_engine" -p "${VYLE_IMAGE_SOURCE##*/}" -s "${thumbDir}/${VYLE_SOURCE_NO_EXTN}.thmb" -a "t1" -t 1600
    SWWW_TRANSITION

    if [[ "${WALLBASH_MODE}" -eq 3 ]]; then
        if [[ ! -f "${dcolDir}/auto/${hashMech}.dcol" ]]; then
            ionice -c 3 nice -n 19 "${scrDir}/swwwallcache.sh" -f "$VYLE_IMAGE_SOURCE"
        fi
        VYLE_DCOL_PATH="${dcolDir}/auto/${hashMech}.dcol"
    else
        if [[ ! -f "${dcolDir}/${dcolMode}/${hashMech}.dcol" ]]; then
            ionice -c 3 nice -n 19 "${scrDir}/swwwallcache.sh" -f "$VYLE_IMAGE_SOURCE"
        fi
        VYLE_DCOL_PATH="${dcolDir}/${dcolMode}/${hashMech}.dcol"
    fi
    [[ -e "${VYLE_DCOL_PATH}" ]] || {
        echo -e "ERROR! DCOL_PATH NOT FOUND!"
        exit 1
    }

    generate_theme "" ""
    generate_theme "_rgba" "_rgba"

    if [[ "$VYLE_THEME" == "Wallbash-Ivy" ]]; then
        DCOL_PATH="$VYLE_CONFIG_HOME/Wall-Dcol"
    else
        DCOL_PATH="$VYLE_CONFIG_HOME/theme/$VYLE_THEME"
    fi
    POPULATE=("${DCOL_PATH}" "${VYLE_CONFIG_HOME}/Wall-Ways")

    export VYLE_CONFIG_HOME=$VYLE_CONFIG_HOME
    export VYLE_CURRENT_IMAGE=$VYLE_IMAGE_SOURCE
    export HYDE_TMQ_IGNORE_TEMPLATES="${VYLE_CONFIGURATION_SKIP_TEMPLATE}"

    source "${scrDir}/tmq.write.sh" \
        --file "${POPULATE[@]}" \
        --proc "${VYLE_CONFIGURATION_CORE}" \
        --no-atomic \
        --defer-run \
        --run-concurrency 0 \
        --disable-fallback \
        --ignore-unbound

    "${scrDir}/wallpaper.${WALLPAPER_CONFIGURATION_BACKEND}.sh" "$VYLE_IMAGE_SOURCE" "$WALLPAPER_SET_FLAGS" &
}

Wall_Select() {
    local wallpapers thumb name
    if [[ -z "${ROFI_WALLPAPER_SCALE}" || "${ROFI_WALLPAPER_SCALE}" -eq 0 ]]; then
        ROFI_WALLPAPER_SCALE=10
    fi
    r_scale="configuration {font : \"${ROFI_WALLPAPER_FONT} ${ROFI_WALLPAPER_SCALE}\";}"
    elem_border=$((hypr_border * 3))

    mon_x_res=$((mon_res * 100 / mon_scale))
    elm_width=$(((28 + 8 + 5) * ROFI_WALLPAPER_SCALE))
    max_avail=$((mon_x_res - (4 * ROFI_WALLPAPER_SCALE)))
    if [[ "${ROFI_WALLPAPER_COLUMN}" -eq 0 || -z "${ROFI_WALLPAPER_COLUMN}" ]]; then
        ROFI_WALLPAPER_COLUMN=$((max_avail / elm_width))
    fi
    r_override="window{width:100%;} 
              listview{columns:${ROFI_WALLPAPER_COLUMN};spacing:5em;}
              element{border-radius:${elem_border}px;orientation:vertical;} 
              element-icon{size:28em;border-radius:0em;} 
              element-text{padding:1em;}"

    choice=$(
        mapfile -d '' wallpapers < <(LC_ALL=C find "${wallSel}" "${WALLPAPER_CONFIGURATION_CUSTOMPATH[@]}" -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.jpeg" \) -print0 | sort -Vzf)
        for indx in "${wallpapers[@]}"; do
            name="${indx##*/}"
            thumb="${thumbDir}/${name%.*}.thmb"
            printf "%s\x00icon\x1f%s\n" "$name" "$thumb"
        done | rofi -dmenu -i -p "Wallpaper" -theme-str "${r_scale}" -theme-str "${r_override}" -config "${rofiConf}" -select "${VYLE_CURRENT_IMAGE##*/}"
    )
    [[ -z "$choice" ]] && exit 0
    sleep 0.5
    Wall_Switch -i "${wallSel}/$choice" "${WALLPAPER_SWWW_ARGS[@]}"
}

case "$1" in
-n | -p)
    Wall_Change "$1"
    ;;
-t)
    Wall_Switch "$@"
    ;;
-r)
    mapfile -t random < <(printf '%s\n' "${VYLE_WALLPAPER_DIRECTORY}"/*)
    setIdx="${random[RANDOM % ${#random[@]}]}"
    Wall_Switch -i "${random}" -n 1
    ;;
-h | --help)
    help_function
    ;;
--populate)
    if [[ ! -e "$VYLE_CACHE_HOME/done" ]]; then
        Wall_Switch -i "${VYLE_CONFIG_HOME}/theme/${VYLE_RESERVED_THEME}/wallpapers/${VYLE_CURRENT_IMAGE##*/}" -w --swww-n -n
        touch "${VYLE_CACHE_HOME}/done"
    fi >/dev/null
    ;;
*)
    Wall_Select
    ;;
esac
