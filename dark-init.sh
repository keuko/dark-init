#!/usr/bin/env bash
set -eu

DARK_DIR="${HOME}/dark-init"
VENV_DIR="${DARK_DIR}/venv"
SRC_DIR="${DARK_DIR}/src"
BASHRC="${HOME}/.bashrc"
PROFILE="${HOME}/.profile"

# Symbols kept simple for broad terminal compatibility
OK="[✓]"
ERR="[✗]"
INFO="[*]"
FORCE="[⚫]"

say() {
    printf '%s %s\n' "$1" "$2"
}

say "$FORCE" "Executing dark-init..."
say "$INFO" "The Force is being gently redirected into your shell."
printf '\n'

if ! command -v python3 >/dev/null 2>&1; then
    say "$ERR" "python3 not found"
    say "$INFO" "Install it first: sudo apt install python3 python3-venv"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    say "$ERR" "git not found"
    say "$INFO" "Install it first: sudo apt install git"
    exit 1
fi

say "$INFO" "Preparing ${DARK_DIR}"
mkdir -p "${DARK_DIR}"

if [ ! -d "${VENV_DIR}" ]; then
    say "$INFO" "Creating Python virtual environment"
    python3 -m venv "${VENV_DIR}"
    say "$OK" "Venv created at ${VENV_DIR}"
else
    say "$OK" "Venv already exists"
fi

REPO_URL="$(git config --get remote.origin.url 2>/dev/null || true)"

if [ -z "${REPO_URL}" ]; then
    say "$INFO" "No git remote.origin.url detected in current repository"
    say "$INFO" "Skipping self-clone for now"
else
    if [ ! -d "${SRC_DIR}/.git" ]; then
        say "$INFO" "Cloning repository into ${SRC_DIR}"
        git clone "${REPO_URL}" "${SRC_DIR}"
        say "$OK" "Repository cloned"
    else
        say "$OK" "Repository already present in ${SRC_DIR}"
    fi
fi

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

# Ubuntu usually loads .profile for login shells and .bashrc for interactive bash.
# Writing to both improves reliability across terminal/login combinations.
add_path_snippet "${BASHRC}"
add_path_snippet "${PROFILE}"

printf '\n'
say "$OK" "dark-init completed"
say "$INFO" "Open a new shell, or run:"
printf '    source "%s"\n' "${BASHRC}"
