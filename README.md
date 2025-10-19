# README.md

A shell script to prepare and run **MTK-based backups** (without userdata).  
It automatically sets up a safe Python environment (PEP 668-compliant), installs required dependencies,  
and then launches `mtk.py` / `mtk` within that environment.

⚠️ **BETA WARNING**  
This tool is currently in **beta** and may not yet be stable.  
Use it **only for testing or personal experiments** — **not for production** or critical backups.  
You are responsible for any potential data loss or system modifications.

---

## Features

- Automatically detects and sets up a virtual environment (`venv`)
- Ensures Python dependencies are installed safely and isolated
- Optionally installs system dependencies (like `libfuse`)
- Runs MTK backup utilities without touching your global Python
- Supports multiple setup modes (`auto`, `venv`, `user`, `system`)

---

## Usage

./mtk_backup.sh [options]

### Options

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help and exit |
| `--setup=auto|venv|user|system` | Choose how to install and run the MTK environment (default: `auto`) |
| `--force-reinstall` | Force reinstall of Python dependencies |
| `--no-os-deps` | Skip automatic installation of system dependencies (like `libfuse`) |
| `--break-system-packages` | Allow installation into system Python (⚠️ **not recommended**) |

---

### Environment Variables

You can also control behavior using environment variables:

| Variable | Default | Description |
|-----------|----------|-------------|
| `MTK_SETUP` | `auto` | Same as `--setup` |
| `FORCE_REINSTALL` | `0` | Force reinstall |
| `QUIET_INSTALL` | `1` | Suppress pip output |
| `AUTO_OS_DEPS` | `1` | Automatically install OS dependencies |
| `ALLOW_BREAK_SYS` | `0` | Same as `--break-system-packages` |
| `MTK_DIR`, `MTK_BIN` | – | Custom paths for MTK installation |
| `SUDO_OPT` | – | Pass additional `sudo` options |

---

## Example

# Run with automatic setup (default)
./backup.sh

# Run using a fresh venv
./backup.sh --setup=venv --force-reinstall

# Skip OS dependency installation
AUTO_OS_DEPS=0 ./backup.sh

---

## Requirements

- Linux or macOS  
- `bash`, `python3`, and `pip`  
- (optional) package manager with `libfuse` support  

---

## License

This project is currently **beta**.  
Feel free to explore or adapt it for your own use,  
but **do not distribute or deploy it in production environments**.
