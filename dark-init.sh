#!/usr/bin/env bash
set -eu

DARK_DIR="${HOME}/dark-init"
VENV_DIR="${DARK_DIR}/venv"
SRC_DIR="${DARK_DIR}/src"
BIN_DIR="${DARK_DIR}/bin"
BASHRC="${HOME}/.bashrc"
PROFILE="${HOME}/.profile"

SCRIPT_PATH="$(readlink -f "$0")"
REPO_DIR="$(dirname "${SCRIPT_PATH}")"

OK="[✓]"
ERR="[✗]"
INFO="[*]"
FORCE="[⚫]"

say() {
    printf '%s %s\n' "$1" "$2"
}

say "$FORCE" "Executing dark-init..."
say "$INFO" "Your home directory is drifting toward the dark side."
say "$INFO" "Changes will be precise. Disturbance minimal."
printf '\n'

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        say "$ERR" "Required command not found: $1"
        exit 1
    fi
}

require_cmd python3
require_cmd git
require_cmd readlink

mkdir -p "${DARK_DIR}"
mkdir -p "${BIN_DIR}"

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
else
    if [ -n "${REPO_URL}" ]; then
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

install_python_wrappers() {
    scripts_dir="${SOURCE_REPO_DIR}/scripts"
    manifest_file="${DARK_DIR}/.installed_python_wrappers"
    current_manifest="${DARK_DIR}/.installed_python_wrappers.new"

    : > "${current_manifest}"

    if [ ! -d "${scripts_dir}" ]; then
        say "$INFO" "No scripts directory found at ${scripts_dir}"
        rm -f "${current_manifest}"
        return 0
    fi

    found_any=0

    for pyfile in "${scripts_dir}"/*.py; do
        if [ ! -f "${pyfile}" ]; then
            continue
        fi

        found_any=1
        name="$(basename "${pyfile}" .py)"
        wrapper="${BIN_DIR}/${name}"

        cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec "${VENV_DIR}/bin/python3" "${pyfile}" "\$@"
EOF
        chmod 0755 "${wrapper}"
        printf '%s\n' "${name}" >> "${current_manifest}"
        say "$OK" "Installed Python command: ${name}"
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

    if [ "${found_any}" -eq 0 ]; then
        say "$INFO" "No Python scripts found in ${scripts_dir}"
    fi
}

install_python_wrappers

PATH_SNIPPET_START="# >>> dark-init PATH >>>"
PATH_SNIPPET_END="# <<< dark-init PATH <<<"

add_path_snippet() {
    target_file="$1"

    if [ ! -f "${target_file}" ]; then
        : > "${target_file}"
    fi

    if grep -Fq "${PATH_SNIPPET_START}" "${target_file}"; then
        say "$OK" "PATH already configured in ${target_file}"
        return 0
    fi

    {
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
        printf '%s\n' "${PATH_SNIPPET_END}"
    } >> "${target_file}"

    say "$OK" "Added PATH snippet to ${target_file}"
}

add_path_snippet "${BASHRC}"
add_path_snippet "${PROFILE}"

printf '\n'
say "$OK" "dark-init completed"
say "$INFO" "Python commands were generated from ${SOURCE_REPO_DIR}/scripts"
say "$INFO" "Open a new shell, or run:"
printf '    source "%s"\n' "${BASHRC}"
printf '\n'
say "$INFO" "Installed commands are in ${BIN_DIR}"
