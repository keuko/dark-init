#!/usr/bin/env python3

import docker
import shlex
import sys


def shell_join(items):
    return " ".join(shlex.quote(str(x)) for x in items)


def normalize_to_list(value):
    """
    Docker inspect vracia niekedy list, niekedy string, niekedy None.
    """
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def format_volume(mount):
    src = mount.get("Source")
    dst = mount.get("Destination")
    mode = mount.get("Mode", "")
    rw = mount.get("RW", True)

    if not src or not dst:
        return None

    # Ak je mode dostupný, použijeme ho. Inak aspoň ro/rw.
    suffix = mode if mode else ("rw" if rw else "ro")
    return f"-v {shlex.quote(src)}:{shlex.quote(dst)}:{suffix}"


def reconstruct_run(container):
    attrs = container.attrs
    config = attrs.get("Config", {})
    host_config = attrs.get("HostConfig", {})
    name = attrs.get("Name", "").lstrip("/")

    image = config.get("Image")
    if not image:
        raise RuntimeError("Nepodarilo sa zistiť image kontajnera.")

    docker_flags = ["docker run -d"]

    # meno
    if name:
        docker_flags.append(f"--name {shlex.quote(name)}")

    # environment
    for env in config.get("Env", []) or []:
        docker_flags.append(f"-e {shlex.quote(env)}")

    # port bindings
    port_bindings = host_config.get("PortBindings") or {}
    for container_port, bindings in port_bindings.items():
        if not bindings:
            continue
        for binding in bindings:
            host_ip = binding.get("HostIp")
            host_port = binding.get("HostPort", "")
            if host_ip and host_ip not in ("", "0.0.0.0"):
                docker_flags.append(
                    f"-p {shlex.quote(host_ip)}:{shlex.quote(host_port)}:{shlex.quote(container_port)}"
                )
            else:
                docker_flags.append(
                    f"-p {shlex.quote(host_port)}:{shlex.quote(container_port)}"
                )

    # volumes / mounts
    for mount in attrs.get("Mounts", []) or []:
        vol = format_volume(mount)
        if vol:
            docker_flags.append(vol)

    # restart policy
    restart = host_config.get("RestartPolicy") or {}
    restart_name = restart.get("Name")
    if restart_name:
        if restart_name == "on-failure" and restart.get("MaximumRetryCount"):
            docker_flags.append(
                f"--restart {restart_name}:{restart['MaximumRetryCount']}"
            )
        else:
            docker_flags.append(f"--restart {shlex.quote(restart_name)}")

    # network
    network_mode = host_config.get("NetworkMode")
    if network_mode and network_mode != "default":
        docker_flags.append(f"--network {shlex.quote(network_mode)}")

    # working dir
    workdir = config.get("WorkingDir")
    if workdir:
        docker_flags.append(f"-w {shlex.quote(workdir)}")

    # hostname
    hostname = config.get("Hostname")
    if hostname:
        docker_flags.append(f"--hostname {shlex.quote(hostname)}")

    # user
    user = config.get("User")
    if user:
        docker_flags.append(f"--user {shlex.quote(user)}")

    # privileged
    if host_config.get("Privileged"):
        docker_flags.append("--privileged")

    # tty / stdin
    if config.get("Tty"):
        docker_flags.append("-t")
    if config.get("OpenStdin"):
        docker_flags.append("-i")

    # readonly rootfs
    if host_config.get("ReadonlyRootfs"):
        docker_flags.append("--read-only")

    # labels
    labels = config.get("Labels") or {}
    for key, value in labels.items():
        if value is None or value == "":
            docker_flags.append(f"--label {shlex.quote(key)}")
        else:
            docker_flags.append(f"--label {shlex.quote(f'{key}={value}')}")


    # ---- KĽÚČOVÁ ČASŤ: entrypoint + jeho argumenty ----
    entrypoint = config.get("Entrypoint")
    cmd = config.get("Cmd")

    entrypoint_list = normalize_to_list(entrypoint)
    cmd_list = normalize_to_list(cmd)

    post_image_args = []

    if entrypoint_list:
        # prvý prvok ide do --entrypoint
        docker_flags.append(f"--entrypoint {shlex.quote(entrypoint_list[0])}")

        # zvyšok MUSÍ ísť až za image
        if len(entrypoint_list) > 1:
            post_image_args.extend(entrypoint_list[1:])

    # potom image
    docker_flags.append(shlex.quote(image))

    # potom entrypoint args + cmd
    post_image_args.extend(cmd_list)

    if post_image_args:
        docker_flags.append(shell_join(post_image_args))

    return " \\\n  ".join(docker_flags)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <container_name_or_id>", file=sys.stderr)
        sys.exit(1)

    container_name = sys.argv[1]

    try:
        client = docker.from_env()
        container = client.containers.get(container_name)
        print(reconstruct_run(container))
    except docker.errors.NotFound:
        print(f"Container '{container_name}' neexistuje.", file=sys.stderr)
        sys.exit(2)
    except docker.errors.DockerException as e:
        print(f"Chyba Docker API: {e}", file=sys.stderr)
        sys.exit(3)
    except Exception as e:
        print(f"Chyba: {e}", file=sys.stderr)
        sys.exit(4)


if __name__ == "__main__":
    main()
