

A beautiful terminal-based installer for AsiraOS using gum for the user interface.

## Prerequisites

- `gum` - A tool for glamorous shell scripts
  ```bash
  # Install gum (choose your method)
  # Debian/Ubuntu
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
  sudo apt update && sudo apt install gum
  
  # Or using go
  go install github.com/charmbracelet/gum@latest
  ```

## Usage

Run the installer:
```bash
./install.sh
```

## Features

- **ASCII Art Banner** - Eye-catching AsiraOS logo
- **Two Setup Modes**:
  - **Basic Setup** - Simple installation process
  - **Advanced Setup** - Full customization options
- **Interactive TUI** - Powered by gum for smooth navigation

## Menu Structure

### Basic Setup
- Select Installation Drive
- Choose Desktop Environment  
- Set User Account
- Configure Network
- Start Installation

### Advanced Setup
- Partition Management
- Bootloader Configuration
- Kernel Parameters
- Custom Packages
- System Services
- Security Settings

## Development

The installer is modular and easy to extend. Each menu option has its own function that can be implemented as needed.
