# Shader Installer Pak for NextUI

![Version](https://img.shields.io/badge/version-v1.0.0-blue)
![Platform](https://img.shields.io/badge/platform-tg5040%20%7C%20tg5050%20%7C%20my355-brightgreen)
![NextUI](https://img.shields.io/badge/NextUI-compatible-orange)

A NextUI pak that browses, downloads, and installs single-pass GLSL shaders directly onto your device from GitHub. Shaders are automatically converted from RetroArch `.glslp` format to minarch-compatible `.cfg` files on install.

---

## Features

- **Browse shaders by source and category** — organized exactly as they appear in the source repositories
- **Single-pass only** — multi-pass shaders are filtered out automatically, since they are incompatible with minarch on low-power devices
- **Automatic `.glslp` → `.cfg` conversion** — no manual editing required, filter settings are preserved
- **Update checking** — compare your installed shader against the latest GitHub commit date
- **Manage installed shaders** — view, check for updates, and delete installed shaders
- **Smart caching** — shader list and commit dates are cached after first run, so subsequent launches are instant
- **GitHub token support** — optional personal access token to avoid API rate limits during cache build
- **Works offline after first cache build** — only needs WiFi to build/refresh the cache or install shaders

---

## Shader Sources

| Source | Description |
|---|---|
| **libretro/glsl-shaders** | The official libretro GLSL shader repository with hundreds of single-pass shaders across many categories |
| **SkyWalker541/PT-SkyWalker541** | PT SkyWalker541 — a pixel transparency shader built specifically for low-power NextUI devices |

---

## Supported Devices

| Device | Platform Tag |
|---|---|
| TrimUI Brick | tg5040 |
| TrimUI Smart Pro S | tg5050 |
| Miyoo A30 / Mini+ | my355 |

---

## Requirements

Before installing, you need to copy a few binaries from other paks already on your device:

- **minui-list** and **minui-presenter** — available in any pak that uses them (e.g. Screenshot Monitor, HTTP Filebrowser, Favorites)
- **jq** — available in HTTP Filebrowser.pak

---

## Installation

### 1. Create the pak folder

On your SD card, create the following folder structure:

```
/mnt/SDCARD/Tools/tg5040/Shader Installer.pak/
    launch.sh
    bin/
        tg5040/
            minui-list
            minui-presenter
        tg5050/
            minui-list
            minui-presenter
        my355/
            minui-list
            minui-presenter
        jq
```

### 2. Copy binaries

Copy **minui-list** and **minui-presenter** from an existing pak for each platform:

```
Tools/tg5040/Screenshot Monitor.pak/bin/tg5040/ → Shader Installer.pak/bin/tg5040/
Tools/tg5040/Screenshot Monitor.pak/bin/tg5050/ → Shader Installer.pak/bin/tg5050/
Tools/tg5040/Screenshot Monitor.pak/bin/my355/  → Shader Installer.pak/bin/my355/
```

Copy **jq**:

```
Tools/tg5040/HTTP Filebrowser.pak/bin/arm64/jq → Shader Installer.pak/bin/jq
```

### 3. Make launch.sh executable

On Mac or Linux:

```bash
chmod +x /Volumes/NEXTUI/Tools/tg5040/Shader\ Installer.pak/launch.sh
```

> **Note:** FAT32 SD cards may not preserve permissions. NextUI handles this automatically for most devices.

### 4. Launch

Eject the SD card, insert into your device, and open **Shader Installer** from the Tools menu.

---

## Usage

### Main Menu

```
Shader Installer
> Browse & Install Shaders
  Manage Installed Shaders
  Refresh Shader List
  Exit
```

### Browse & Install Shaders

Navigate by source → category → shader. On first launch the shader list is built automatically — this takes 5-6 minutes as it fetches shaders and update info from GitHub. Subsequent launches open instantly from cache.

```
Browse Shaders
> SkyWalker541 (1)
  libretro shaders (155)
```

```
libretro shaders
> crt (24)
  handheld (8)
  pixel-art (12)
  scanlines (7)
  ...
```

Selecting a shader shows a confirmation prompt before downloading:

```
Install crt-lottes?
> Install
  Cancel
```

### Manage Installed Shaders

View all installed shaders with options to check for updates or delete:

```
Installed Shaders
> crt-lottes
  PT_SkyWalker541
```

```
crt-lottes
> Check for Update
  Delete
  Cancel
```

**Check for Update** fetches the latest commit date from GitHub and compares it to your installed version:

- If up to date: `crt-lottes is up to date. Last updated: 2024-03-15`
- If update available: prompts to install the update

### Refresh Shader List

Re-fetches the full shader list and commit dates from GitHub. Use this when new shaders have been released. Takes 5-6 minutes.

---

## Where Shaders Are Installed

```
/mnt/SDCARD/Shaders/
    ShaderName.cfg        ← minarch config (auto-converted from .glslp)
    glsl/
        ShaderName.glsl   ← shader source
```

Shaders appear in minarch's shader selector immediately after install.

---

## GitHub API Rate Limits

GitHub limits unauthenticated API requests to 60 per hour. The cache build makes several hundred requests, so if you hit the rate limit the pak will display a message and walk you through setting up a free personal access token.

### Setting Up a GitHub Token (Optional)

A token is only needed if you hit the rate limit during a cache build. Most users will never need one.

1. Go to [github.com](https://github.com) and sign in
2. Click your profile picture → **Settings**
3. Scroll to **Developer settings** → **Personal access tokens** → **Tokens (classic)**
4. Click **Generate new token (classic)**
5. Give it a name (e.g. `Shader Installer Pak`)
6. Set expiration as desired
7. **Do not check any scopes** — no permissions are needed for public repos
8. Click **Generate token** and copy it
9. On your SD card, create a plain text file at:

```
/mnt/SDCARD/.userdata/shared/Shader Installer/github_token.txt
```

10. Paste your token as the only content of the file
11. Relaunch Shader Installer

With a token, the rate limit is raised to 5000 requests per hour.

---

## File Locations

| File | Location |
|---|---|
| Shader list cache | `/mnt/SDCARD/.userdata/shared/Shader Installer/cache/shader_list.txt` |
| Installed dates | `/mnt/SDCARD/.userdata/shared/Shader Installer/cache/installed/` |
| GitHub token | `/mnt/SDCARD/.userdata/shared/Shader Installer/github_token.txt` |
| Log file | `/mnt/SDCARD/Logs/Shader Installer.txt` |

---

## Changelog

### v1.0.0
- Initial release
- Browse and install single-pass GLSL shaders from libretro/glsl-shaders and SkyWalker541/PT-SkyWalker541
- Automatic `.glslp` → `.cfg` conversion for minarch compatibility
- Filter preservation (NEAREST/LINEAR) from original shader presets
- Multi-pass shader filtering
- Update checking per installed shader
- Manage installed shaders (view, update, delete)
- Smart caching with commit dates
- GitHub personal access token support for rate limit bypass
- Supports tg5040, tg5050, and my355 platforms

---

## Credits

- Shader sources: [libretro/glsl-shaders](https://github.com/libretro/glsl-shaders) and [SkyWalker541/PT-SkyWalker541](https://github.com/SkyWalker541/PT-SkyWalker541)
- Built for [NextUI](https://github.com/LoveRetro/NextUI) by LoveRetro
- UI powered by [minui-list](https://github.com/josegonzalez/minui-list) and [minui-presenter](https://github.com/josegonzalez/minui-presenter) by josegonzalez
