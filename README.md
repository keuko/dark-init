# dark-init

```bash
cd /home/michalarbet/ultimum/git/dark-init
./install.sh
source ~/.bashrc
```

```bash
dark-init ls
dark-init status
dark-init update
dark-init update --force
dark-init install
```

The `.bashrc` hook checks the Git remote at most once per hour. Override it with:

```bash
export DARK_INIT_UPDATE_INTERVAL=21600
```
