#!/usr/bin/env bash
set -eu

DARK_DIR="${HOME}/dark-init"
VENV_DIR="${DARK_DIR}/venv"
SRC_DIR="${DARK_DIR}/src"
BIN_DIR="${DARK_DIR}/bin"
BASHRC="${HOME}/.bashrc"
PROFILE="${HOME}/.profile"
UPDATE_STAMP="${DARK_DIR}/.last_update_check"
UPDATE_INTERVAL="${DARK_INIT_UPDATE_INTERVAL:-3600}"

SCRIPT_PATH="$(readlink -f "$0")"
REPO_DIR="$(dirname "${SCRIPT_PATH}")"

OK="[✓]"
ERR="[✗]"
INFO="[*]"
FORCE="[⚫]"

say() {
    printf '%s %s\n' "$1" "$2"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        say "$ERR" "Required command not found: $1"
        exit 1
    fi
}

repo_source_dir() {
    if [ -d "${REPO_DIR}/.git" ] && [ -d "${REPO_DIR}/scripts" ]; then
        printf '%s\n' "${REPO_DIR}"
    elif [ -d "${SRC_DIR}/.git" ] && [ -d "${SRC_DIR}/scripts" ]; then
        printf '%s\n' "${SRC_DIR}"
    elif [ -d "${REPO_DIR}/scripts" ]; then
        printf '%s\n' "${REPO_DIR}"
    else
        return 1
    fi
}

show_help() {
    cat <<'EOF_HELP'
Usage: dark-init [command]

Commands:
  install           Install or refresh dark-init and all script wrappers
  update            Check Git and install changes when a new commit exists
  list, ls          List available scripts and their installation status
  status            Show repository and update status
  help              Show this help

Environment:
  DARK_INIT_UPDATE_INTERVAL
                    Minimum seconds between automatic Git checks (default: 3600)
EOF_HELP
}

list_scripts() {
    source_dir="$(repo_source_dir)" || {
        say "$ERR" "Could not find the dark-init source directory"
        exit 1
    }
    scripts_dir="${source_dir}/scripts"

    printf '%-24s %-10s %-11s %s\n' "COMMAND" "TYPE" "STATUS" "SOURCE"
    printf '%-24s %-10s %-11s %s\n' "------------------------" "----------" "-----------" "------"

    found=0
    for script_file in "${scripts_dir}"/*; do
        [ -f "${script_file}" ] || continue
        filename="$(basename "${script_file}")"
        case "${filename}" in
            *.py) name="${filename%.py}"; script_type="Python" ;;
            *.sh) name="${filename%.sh}"; script_type="Shell" ;;
            *) continue ;;
        esac

        found=1
        if [ -x "${BIN_DIR}/${name}" ]; then
            status="installed"
        else
            status="available"
        fi
        printf '%-24s %-10s %-11s %s\n' "${name}" "${script_type}" "${status}" "scripts/${filename}"
    done

    if [ "${found}" -eq 0 ]; then
        say "$INFO" "No supported scripts (*.py or *.sh) found"
    fi
}

update_due() {
    [ "${1:-}" = "--force" ] && return 0
    [ ! -f "${UPDATE_STAMP}" ] && return 0

    now="$(date +%s)"
    last="$(cat "${UPDATE_STAMP}" 2>/dev/null || printf '0')"
    case "${last}" in *[!0-9]*|'') last=0 ;; esac
    [ $((now - last)) -ge "${UPDATE_INTERVAL}" ]
}

update_repo() {
    quiet=0
    force=0
    for arg in "$@"; do
        case "${arg}" in
            --quiet) quiet=1 ;;
            --force) force=1 ;;
            *) say "$ERR" "Unknown update option: ${arg}"; exit 2 ;;
        esac
    done

    source_dir="$(repo_source_dir)" || {
        [ "${quiet}" -eq 1 ] || say "$ERR" "Could not find the dark-init repository"
        return 1
    }

    if [ ! -d "${source_dir}/.git" ]; then
        [ "${quiet}" -eq 1 ] || say "$INFO" "Update skipped: ${source_dir} is not a Git checkout"
        return 0
    fi

    if [ "${force}" -eq 0 ] && ! update_due; then
        return 0
    fi

    mkdir -p "${DARK_DIR}"
    date +%s > "${UPDATE_STAMP}"

    upstream="$(git -C "${source_dir}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [ -z "${upstream}" ]; then
        [ "${quiet}" -eq 1 ] || say "$INFO" "Update skipped: current branch has no upstream"
        return 0
    fi

    if ! git -C "${source_dir}" diff --quiet || ! git -C "${source_dir}" diff --cached --quiet; then
        [ "${quiet}" -eq 1 ] || say "$INFO" "Update skipped: repository has local changes"
        return 0
    fi

    if ! git -C "${source_dir}" fetch --quiet; then
        [ "${quiet}" -eq 1 ] || say "$ERR" "Could not fetch Git updates"
        return 0
    fi

    local_head="$(git -C "${source_dir}" rev-parse HEAD)"
    remote_head="$(git -C "${source_dir}" rev-parse '@{upstream}')"

    if [ "${local_head}" = "${remote_head}" ]; then
        [ "${quiet}" -eq 1 ] || say "$OK" "dark-init is already up to date"
        return 0
    fi

    if ! git -C "${source_dir}" merge-base --is-ancestor HEAD '@{upstream}'; then
        [ "${quiet}" -eq 1 ] || say "$ERR" "Update skipped: local branch cannot be fast-forwarded"
        return 0
    fi

    [ "${quiet}" -eq 1 ] || say "$INFO" "New dark-init version found; updating"
    git -C "${source_dir}" pull --ff-only --quiet
    exec "${source_dir}/dark-init.sh" install ${quiet:+}
}

show_status() {
    source_dir="$(repo_source_dir)" || {
        say "$ERR" "Could not find the dark-init source directory"
        exit 1
    }

    say "$INFO" "Source: ${source_dir}"
    say "$INFO" "Commands: ${BIN_DIR}"
    if [ -d "${source_dir}/.git" ]; then
        branch="$(git -C "${source_dir}" branch --show-current 2>/dev/null || true)"
        commit="$(git -C "${source_dir}" rev-parse --short HEAD 2>/dev/null || true)"
        say "$INFO" "Git: ${branch:-detached} @ ${commit:-unknown}"
    else
        say "$INFO" "Git: unavailable (not a Git checkout)"
    fi

    if [ -f "${UPDATE_STAMP}" ]; then
        last="$(cat "${UPDATE_STAMP}" 2>/dev/null || true)"
        case "${last}" in
            *[!0-9]*|'') ;;
            *) say "$INFO" "Last automatic update check: $(date -d "@${last}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "${last}")" ;;
        esac
    else
        say "$INFO" "Last automatic update check: never"
    fi
}

command="${1:-install}"
case "${command}" in
    update)
        shift
        update_repo "$@"
        exit $?
        ;;
    list|ls)
        list_scripts
        exit 0
        ;;
    status)
        show_status
        exit 0
        ;;
    help|-h|--help)
        show_help
        exit 0
        ;;
    install)
        shift
        ;;
    *)
        say "$ERR" "Unknown command: ${command}"
        show_help
        exit 2
        ;;
esac

say "$FORCE" "Executing dark-init..."
say "$INFO" "Your home directory is drifting toward the dark side."
say "$INFO" "Changes will be precise. Disturbance minimal."
printf '\n'

require_cmd python3
require_cmd git
require_cmd readlink

mkdir -p "${DARK_DIR}" "${BIN_DIR}"

if [ ! -d "${VENV_DIR}" ]; then
    say "$INFO" "Creating Python virtual environment"
    python3 -m venv "${VENV_DIR}"
    say "$OK" "Venv created at ${VENV_DIR}"
else
    say "$OK" "Venv already exists"
fi

SOURCE_REPO_DIR=""
REPO_URL="$(git -C "${REPO_DIR}" config --get remote.origin.url 2>/dev/null || true)"

if [ -d "${REPO_DIR}/scripts" ]; then
    SOURCE_REPO_DIR="${REPO_DIR}"
    say "$OK" "Using local repository checkout at ${SOURCE_REPO_DIR}"
elif [ -n "${REPO_URL}" ]; then
    if [ ! -d "${SRC_DIR}/.git" ]; then
        say "$INFO" "Cloning repository into ${SRC_DIR}"
        git clone "${REPO_URL}" "${SRC_DIR}"
        say "$OK" "Repository cloned"
    else
        say "$OK" "Repository already present in ${SRC_DIR}"
    fi
    SOURCE_REPO_DIR="${SRC_DIR}"
else
    say "$ERR" "Could not find local scripts directory or git remote.origin.url"
    exit 1
fi

if [ "${SOURCE_REPO_DIR}" != "${SRC_DIR}" ]; then
    if [ -L "${SRC_DIR}" ] || [ -e "${SRC_DIR}" ]; then
        rm -rf "${SRC_DIR}"
    fi
    ln -s "${SOURCE_REPO_DIR}" "${SRC_DIR}"
    say "$OK" "Linked ${SRC_DIR} -> ${SOURCE_REPO_DIR}"
fi

if [ -x "${VENV_DIR}/bin/pip" ]; then
    say "$INFO" "Upgrading base Python tooling in venv"
    "${VENV_DIR}/bin/python3" -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
fi

if [ -f "${SOURCE_REPO_DIR}/requirements.txt" ]; then
    say "$INFO" "Installing Python requirements"
    "${VENV_DIR}/bin/python3" -m pip install -r "${SOURCE_REPO_DIR}/requirements.txt"
    say "$OK" "Requirements installed"
else
    say "$INFO" "No requirements.txt found, skipping Python dependencies"
fi

install_script_wrappers() {
    scripts_dir="${SOURCE_REPO_DIR}/scripts"
    manifest_file="${DARK_DIR}/.installed_commands"
    current_manifest="${DARK_DIR}/.installed_commands.new"

    : > "${current_manifest}"
    [ -d "${scripts_dir}" ] || { rm -f "${current_manifest}"; return 0; }

    found_any=0
    for script_file in "${scripts_dir}"/*; do
        [ -f "${script_file}" ] || continue
        filename="$(basename "${script_file}")"
        case "${filename}" in
            *.py) name="${filename%.py}"; interpreter="${VENV_DIR}/bin/python3"; script_type="Python" ;;
            *.sh) name="${filename%.sh}"; interpreter="/usr/bin/env bash"; script_type="shell" ;;
            *) continue ;;
        esac

        [ -n "${name}" ] || { say "$ERR" "Invalid script filename: ${filename}"; exit 1; }
        if grep -Fxq "${name}" "${current_manifest}" 2>/dev/null; then
            say "$ERR" "Duplicate command name '${name}' in ${scripts_dir}"
            exit 1
        fi

        found_any=1
        wrapper="${BIN_DIR}/${name}"
        cat > "${wrapper}" <<EOF_WRAPPER
#!/usr/bin/env bash
exec ${interpreter} "${script_file}" "\$@"
EOF_WRAPPER
        chmod 0755 "${wrapper}"
        printf '%s\n' "${name}" >> "${current_manifest}"
        say "$OK" "Installed ${script_type} command: ${name}"
    done

    if [ -f "${manifest_file}" ]; then
        while IFS= read -r old_name; do
            [ -n "${old_name}" ] || continue
            if ! grep -Fxq "${old_name}" "${current_manifest}" 2>/dev/null; then
                rm -f "${BIN_DIR}/${old_name}"
                say "$OK" "Removed stale command: ${old_name}"
            fi
        done < "${manifest_file}"
    fi

    mv -f "${current_manifest}" "${manifest_file}"
    [ "${found_any}" -ne 0 ] || say "$INFO" "No supported scripts (*.py or *.sh) found in ${scripts_dir}"
}

install_script_wrappers

cat > "${BIN_DIR}/dark-init" <<EOF_CLI
#!/usr/bin/env bash
exec "${SOURCE_REPO_DIR}/dark-init.sh" "\$@"
EOF_CLI
chmod 0755 "${BIN_DIR}/dark-init"
say "$OK" "Installed dark-init management command"

PATH_SNIPPET_START="# >>> dark-init >>>"
PATH_SNIPPET_END="# <<< dark-init <<<"

add_shell_snippet() {
    target_file="$1"
    tmp_file="${target_file}.dark-init.tmp"
    [ -f "${target_file}" ] || : > "${target_file}"

    awk -v start="${PATH_SNIPPET_START}" -v end="${PATH_SNIPPET_END}" '
        $0 == start { skip=1; next }
        $0 == end   { skip=0; next }
        !skip       { print }
    ' "${target_file}" > "${tmp_file}"

    {
        cat "${tmp_file}"
        printf '\n%s\n' "${PATH_SNIPPET_START}"
        printf 'if [ -d "%s" ]; then\n' "${BIN_DIR}"
        printf '    case ":$PATH:" in\n'
        printf '        *:"%s":*) ;;\n' "${BIN_DIR}"
        printf '        *) export PATH="%s:$PATH" ;;\n' "${BIN_DIR}"
        printf '    esac\n'
        printf 'fi\n'
        printf 'if [ -d "%s/bin" ]; then\n' "${VENV_DIR}"
        printf '    case ":$PATH:" in\n'
        printf '        *:"%s/bin":*) ;;\n' "${VENV_DIR}"
        printf '        *) export PATH="%s/bin:$PATH" ;;\n' "${VENV_DIR}"
        printf '    esac\n'
        printf 'fi\n'
        if [ "${target_file}" = "${BASHRC}" ]; then
            printf 'if command -v dark-init >/dev/null 2>&1; then\n'
            printf '    dark-init update --quiet >/dev/null 2>&1 || true\n'
            printf 'fi\n'
        fi
        printf '%s\n' "${PATH_SNIPPET_END}"
    } > "${target_file}"

    rm -f "${tmp_file}"
    say "$OK" "Updated dark-init snippet in ${target_file}"
}

add_shell_snippet "${BASHRC}"
add_shell_snippet "${PROFILE}"

printf '\n'
say "$OK" "dark-init completed"
say "$INFO" "Use 'dark-init list' to see available commands"
say "$INFO" "Use 'dark-init update --force' to check for updates immediately"
say "$INFO" "Open a new shell, or run: source \"${BASHRC}\""
