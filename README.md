# 🛠️ System Setup & Container Management Script

> A shell script for setting up a Linux system and managing LXC containers.
> It has been tested and made for Debian 11 (Bullseye).




## 📖 Table of Contents

- [📝 Overview](#-overview)
- [🚀 Services](#-services)
- [💻 Usage](#-usage)
- [🔒 Safety and Security](#-safety-and-security)
- [⚙️ Improvements](#️-improvements)
- [⚠️ Disclaimer](#️-disclaimer)

## 📝 Overview

This shell script is designed to set up and manage a Linux system running various services in LXC (Linux Containers) and Docker. It provides tools for system setup, creating new containers, and installing various packages. The script also configures Nginx, Certbot, WireGuard, and Docker. It is designed to be run on a fresh Debian 11 (Bullseye) system, but it can be modified to work on other Linux distributions. It has been created with the following goals in mind:

- **Simplicity:** The script is designed to be easy to use and understand. It is also designed to be easy to modify and extend.
- **Security:** The script is designed to be secure and safe to use. It is also designed to be easy to audit and review.
- **Flexibility:** The script is designed to be flexible and easy to modify. It is also designed to be easy to extend and customize.
- **Production-Ready:** The script is designed to be production-ready and easy to use in a production environment. It is also designed to be easy to maintain and update.

## 🚀 Services

The script can set up containers for the following services:

- Jenkins 🔧
- Prometheus 📊
- Grafana 📈
- Tolgee 🌐
- Appsmith 🛠️
- n8n 🔄
- Owncloud ☁️

## 💻 Usage

To use the script, run it as the root user. You will then be prompted to either set up the system or create a new container.

```bash
sudo ./main.sh
```

- For system setup, you will be asked to provide your domain(s), email, and allowed IP addresses.
- For container creation, you will be prompted to enter a container name, network interface, and IP address.

## 🔒 Safety and Security

Please note that this script requires root access and may pose a risk if run on a production system without proper checks. It is also necessary to ensure that inputs provided at the prompts are validated and safe.

## ⚙️ Improvements

The following improvements are recommended for this script:

- Run as a non-root user when possible and only elevate privileges when necessary. 🧑‍💻
- Add validation for all user inputs to prevent issues like shell injection attacks. 🛡️
- Add error handling after each command to ensure that the script stops execution if an error occurs. ❌
- Ensure that all services use encrypted connections where possible. 🔒
- Implement logging for debugging and auditing purposes. 📝
- Use environment variables for sensitive data such as database passwords. 🗝️
- Modularize the script into smaller scripts or functions for easier maintenance and testing. 🧩
- Add support for other Linux distributions. 🐧

## ⚠️ Disclaimer

Use this script at your own risk. Always review and understand a script before running it, especially when it requires root access.
