# Phase 1 — VirtualBox setup

> **Status: not done.** This is the runbook for the host. None of these clicks have been performed for this repository, and the screenshots below are placeholders.

The host is Windows 11 Home with 32 GB of RAM. Virtual machines will live in `E:\VMs`. The hypervisor is VirtualBox 7.2. Use 7.2.2 or a later 7.2 update. VirtualBox 7.2.0 had a bug where the emulated TPM was invisible to some guests; 7.2.2 fixed that. Windows 11 was less affected than other guests, and starting on 7.2.2 avoids the question.

When this phase is actually finished, both guests will be installed, Guest Additions will be installed, each VM will have a powered-off baseline snapshot, and the only network attachment will be NAT Network `LabNAT`.

Related pages: [README](../README.md), [Phase 2 domain controller](02-domain-controller.md).

## What you need before the wizard

- Windows 11 Home, 64-bit, with virtualization enabled in firmware (Intel VT-x or AMD-V).
- About 32 GB of RAM on the host. The two guests are planned at 4 GB each.
- Free space on `E:` for two dynamic disks (60 GB and 64 GB maximum) plus snapshot growth. Dynamic disks do not consume the full size on day one. Snapshots can.
- A local administrator on the host.
- The VirtualBox 7.2 Windows installer from [https://www.virtualbox.org/wiki/Downloads](https://www.virtualbox.org/wiki/Downloads).
- Windows Server 2022 Evaluation from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022).
- Windows 11 Enterprise Evaluation from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise).

Microsoft asks for a free account before the ISO download. That account stays with you. Do not put it in this repository.

The evaluation ISOs are the only installation media this lab uses. Server 2022 Evaluation runs for 180 days. Check it later with `slmgr /dlv`. Rearm is limited. Windows 11 Enterprise Evaluation runs for 90 days. Write the install date in your own notes when you install. Do not treat either license as permanent, and do not use the evaluation for a business.

The Extension Pack is not required for the NAT Network, EFI, TPM 2.0, or Secure Boot. Skip it unless you later need USB 2.0 or 3.0. If you do install it, the pack version must match VirtualBox exactly, and you download it from the same Oracle page.

## Install VirtualBox

1. Run the Windows installer and accept the default components, including the network drivers it wants to install.
2. Reboot the host if the installer asks.
3. Open VirtualBox Manager and confirm the version is 7.2.2 or later. Help > About.

> TODO: add screenshot
>
> `docs/screenshots/vbox-version.png`
>
> The About dialog showing the 7.2.x build you actually installed.

## Store machines on E:\VMs

1. File > Preferences > General.
2. Set the default machine folder to `E:\VMs`.
3. Create the folder first if it does not exist.
4. When you create each VM, the folder field on the name page should start with `E:\VMs`. If it does not, change it before you click through. A VM created on `C:` is easy to fill the system disk with, and it is annoying to move later.

> TODO: add screenshot
>
> `docs/screenshots/machine-folder.png`
>
> Preferences showing the default machine folder `E:\VMs`.

## Create the NAT Network

VirtualBox has three attachments that people mix up:

| Attachment | What it does | Use it here? |
| --- | --- | --- |
| NAT | Each VM is hidden behind its own NAT. Guests do not easily talk to each other. | No |
| NAT Network | Guests share one virtual LAN, talk to each other, and reach the internet through NAT. The home LAN does not see them. | Yes. Name it `LabNAT` |
| Bridged | The VM sits on the home LAN and can see household devices. A DHCP server in the VM can offer addresses to the house. | No. Not on any adapter |

Official description of the NAT Network service: [VirtualBox 7.2 networking](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/networkingdetails.html).

### In Network Manager

1. Shut the guests down if any exist. Do not edit the host network from a saved state.
2. Open Network Manager: File > Tools > Network Manager. On a layout where that menu is collapsed, open Tools in the VirtualBox Manager sidebar and choose Network.
3. Select NAT Networks and create a network.
4. Name: `LabNAT`.
5. IPv4 prefix: `10.0.10.0/24`.
6. Enable the network.
7. Leave DHCP enabled for now. The operating-system installers need an address so Windows Update can run. You will turn this off at the start of Phase 2, before Windows Server becomes a DHCP server.
8. Disable IPv6 on this NAT Network. The guests can keep IPv6 enabled inside Windows. The lab DNS design is IPv4, and an IPv6 resolver from the NAT engine would be a second path around DC01.
9. Do not add a port-forward rule. Nothing in this lab needs a service published on the host.

VirtualBox uses the first address of that prefix as the NAT gateway. For `10.0.10.0/24` that is `10.0.10.1`. The manual notes that the gateway address can differ. Read it before you set the static IP in Phase 2. In Network Manager, or from a command prompt:

```text
VBoxManage list natnetworks
```

If the gateway is not `10.0.10.1`, use the address you see as `-DefaultGateway` in `scripts/01-Set-ServerBasics.ps1` and as the DHCP router option in `scripts/03-Configure-DHCP.ps1`. Do not guess.

The same settings as a command, if you would rather check the GUI result or recreate the network:

```text
VBoxManage natnetwork add --netname LabNAT --network 10.0.10.0/24 --enable --dhcp on --ipv6 off
VBoxManage list natnetworks
```

Do not run `add` if `LabNAT` already exists. To turn DHCP off later:

```text
VBoxManage natnetwork modify --netname LabNAT --dhcp off
```

> TODO: add screenshot
>
> `docs/screenshots/nat-network.png`
>
> `LabNAT` with prefix `10.0.10.0/24`. Take it again after DHCP is disabled and say which state the image shows.

## Why Bridged is out

A Bridged adapter joins the home network. Broadcasts from the VM, including DHCP offers, reach whatever else is on that network. This lab's DHCP scope is for CLIENT01, not for phones, TVs, or anyone else's PC. NAT Network keeps those broadcasts inside `LabNAT` and still allows outbound internet.

After both VMs exist, open each VM's network settings and read the attachment. It must say NAT Network, and the name must be `LabNAT`. If it says Bridged Adapter, change it before you start the guest. Power the guest off before changing the attachment. Discard a saved state rather than changing the NIC underneath it.

## Create DC01

Skip unattended install. VirtualBox unattended setup asks for a password and can store it in the VM configuration. You will set the Administrator password yourself at the Windows console, and you will not put it in this repository or in a screenshot.

1. Machine > New.
2. Name: `DC01`.
3. Folder: `E:\VMs`.
4. ISO: the Server 2022 evaluation ISO.
5. Type: Microsoft Windows. Version: Windows 2022 (64-bit). If the wizard offers to skip unattended install, skip it. If a username or password field is visible, you are on the unattended path. Go back and turn that off.
6. Base memory: 4096 MB. Processors: 2.
7. Hard disk: Create a virtual hard disk now. VDI, dynamically allocated, 60 GB.
8. Finish, then open Settings before the first boot and confirm:

| Page | Setting |
| --- | --- |
| System > Motherboard | EFI off. TPM off. Secure Boot off. Server 2022 does not need them for this lab. |
| System > Processor | 2 CPUs. |
| Display | Default is fine. |
| Network > Adapter 1 | Enable. Attached to: NAT Network. Name: `LabNAT`. |
| Network > Adapter 2 | Disabled. |
| Audio, USB | Disabled is fine. |

> TODO: add screenshot
>
> `docs/screenshots/dc01-network.png`
>
> Adapter 1 attached to NAT Network `LabNAT`.

## Create CLIENT01

Windows 11 will refuse to install without EFI, TPM 2.0, Secure Boot, 2 CPUs, and 4 GB of RAM. Set the firmware before the first boot. Power the VM off before you change any of these later.

1. Machine > New.
2. Name: `CLIENT01`.
3. Folder: `E:\VMs`.
4. ISO: the Windows 11 Enterprise evaluation ISO.
5. Type: Microsoft Windows. Version: Windows 11 (64-bit).
6. Skip unattended install, for the same reason as DC01.
7. Base memory: 4096 MB. Processors: 2.
8. Hard disk: VDI, dynamically allocated, 64 GB.
9. Finish, then Settings:

| Page | Setting |
| --- | --- |
| System > Motherboard | Enable EFI. TPM: 2.0. Enable Secure Boot. If Reset keys to default is available, use it so the VM has the current default Secure Boot certificates. |
| System > Processor | 2 CPUs. |
| Display | Video memory 128 MB. Graphics controller: VBoxSVGA. |
| Network > Adapter 1 | Enable. Attached to: NAT Network. Name: `LabNAT`. |
| Network > Adapter 2 | Disabled. |

Do not clear the TPM after Windows is installed unless you are throwing the VM away and starting over. Secure Boot keys live in the VM's NVRAM. TPM state is separate.

> TODO: add screenshot
>
> `docs/screenshots/client01-firmware.png`
>
> Motherboard page with EFI, TPM 2.0, and Secure Boot enabled.

The lab plan does not bypass the Windows 11 hardware checks. If setup says this PC can't run Windows 11, fix the VirtualBox settings above and confirm the OS type is Windows 11 (64-bit). A registry bypass would hide a misconfiguration.

## Install the operating systems

VirtualBox DHCP on `LabNAT` is still enabled during this section so each guest can reach Windows Update. You turn it off in Phase 2.

Boot order should try the optical drive before the hard disk for the first start. The wizard usually attaches the ISO. If the VM boots to a blank disk, open Settings > Storage and attach the ISO to the optical drive, then start again.

### DC01

Follow [02-domain-controller.md](02-domain-controller.md) from the Server 2022 setup screens through the first sign-in. The short version: Windows Server 2022 Standard Evaluation (Desktop Experience), custom install onto the 60 GB disk, Administrator password typed at the console and not recorded here.

Do not pick the option without "Desktop Experience". That install is Server Core. The rest of this lab uses Server Manager and the management consoles.

### CLIENT01

1. Language and keyboard, then Install now.
2. If it asks for a product key, choose "I don't have a product key".
3. Select Windows 11 Enterprise if more than one edition is listed. The evaluation ISO often offers only that edition.
4. Custom install. Select the unallocated 64 GB disk. Next.
5. After the reboot, the out-of-box experience varies by Windows 11 build. The end state you want is a local administrator account, the computer named `CLIENT01`, not joined to any domain, and not signed in with a Microsoft account or a work Azure AD tenant. Domain join is Phase 3, and it joins `lab.local`, not a cloud tenant.
6. If you see a local-account or "domain join instead" path, use the local account.
7. If setup insists on a network account, shut down, set Adapter 1 to Not attached, start again, and take the offline local-account path. When the desktop is up, shut down and set Adapter 1 back to NAT Network `LabNAT`.
8. If the name was not set during setup, rename the PC to `CLIENT01` in Settings > System > About, or with `Rename-Computer -NewName CLIENT01 -Restart` from an elevated PowerShell.

Four gigabytes is the Windows 11 minimum. The desktop will feel tight. That matches the spec in the README.

## Guest Additions

Install Guest Additions after the first successful sign-in on each VM, before the baseline snapshot. They provide the display driver, a cleaner mouse, and clock sync with the host. Kerberos later fails if the clocks drift by more than five minutes, so the host clock needs to be right, and Guest Additions time sync is what keeps a single-DC lab matched to that clock.

1. Sign in to the guest.
2. From the VM window menu, Devices > Insert Guest Additions CD image.
3. In the guest, open File Explorer if AutoPlay does not run. On Server 2022, open This PC and the optical drive.
4. Run `VBoxWindowsAdditions.exe`. Accept the device software prompts. Reboot when it asks.
5. After reboot, the VM window should resize with the guest desktop.

If the menu item does nothing, the ISO is on the host at `C:\Program Files\Oracle\VirtualBox\VBoxGuestAdditions.iso`. Devices > Optical Drives > Choose a disk file, and select that ISO.

Leave the shared clipboard off until you need it. Do not enable a shared folder that contains personal documents or password managers. This repository has no secrets, so a later copy of the repo into the guest is fine. During Phase 1 you only need the operating system.

> TODO: add screenshot
>
> `docs/screenshots/guest-additions.png`
>
> Guest Additions reported as installed, from the VM window status bar or from Programs and Features. One image per guest is enough if the captions say which VM.

## Snapshots

Take snapshots with the VM powered off. A snapshot of a running machine includes memory and is easier to get wrong. Snapshots are a rewind button for a lab, not a backup. The differencing disk grows while the snapshot exists, and a long chain fills `E:`.

Suggested names, once each state is real:

| Snapshot | When |
| --- | --- |
| `01-os-installed` | Operating system installed, Windows Update run, Guest Additions installed, powered off |
| `02-static-ip-workgroup` | DC01 renamed and on `10.0.10.10`, still a workgroup, powered off. Phase 2. |
| `03-domain-controller` | DC01 promoted and rebooted, powered off. Phase 2. |
| `04-ou-and-users` | OUs and fictional users exist, powered off. Phase 2. |

Four snapshots, not one after every click. Delete a snapshot you no longer need so VirtualBox can merge the disk.

Restoring a domain controller snapshot from before a client joined, or from before a password change, can make that client fail to sign in. With one domain controller the recovery is to rejoin the client or reset the computer account. That problem does not exist yet, because the client is not joined. Remember it before you restore casually in a later phase.

> TODO: add screenshot
>
> `docs/screenshots/snapshots-baseline.png`
>
> The snapshot list with `01-os-installed` for DC01 and for CLIENT01.

## Checks before you call Phase 1 done

Run these on the host and in the guests when you build this. They are the checks, not results from a build that already happened.

- VirtualBox Help > About shows 7.2.2 or a later 7.2 build.
- Both VM folders are under `E:\VMs`.
- `VBoxManage list natnetworks` shows `LabNAT` and `10.0.10.0/24`.
- Each VM has one enabled adapter, attached to NAT Network `LabNAT`.
- CLIENT01 settings show EFI, TPM 2.0, and Secure Boot.
- DC01 is Server 2022 with a desktop, not Server Core.
- CLIENT01 is named `CLIENT01` and is not domain-joined.
- Guest Additions are installed on both.
- A powered-off snapshot `01-os-installed` exists for both.
- You can sign in to each guest. You have not written the passwords into git.

Inside CLIENT01, after it is installed, these are the checks for the firmware. Run them in PowerShell:

```powershell
Get-Tpm
Confirm-SecureBootUEFI
```

What you want, once the settings are right: `Get-Tpm` reports a TPM that is present and ready, specification version 2.0, and `Confirm-SecureBootUEFI` returns `True`. If either check fails, shut down and fix the motherboard settings. Do not bypass the check inside Windows.

## Troubleshooting

**The New VM wizard does not list 64-bit Windows versions.** Firmware virtualization is off, or the host is already running another hypervisor that holds it. Enable VT-x or AMD-V in firmware, then reboot the host.

**The VM window shows a turtle instead of a V chip.** VirtualBox is using the slow Windows hypervisor backend. It still runs. For a lab that will boot a domain controller, the native backend is more pleasant. On a personal Windows 11 Home PC the features that force the turtle are Memory Integrity (Core isolation), Virtual Machine Platform, and Windows Hypervisor Platform. Turning those off is a security tradeoff on the host, not a change inside the lab VMs. Leave them on if you want that protection and can tolerate the speed. If you turn them off, reboot the host and start the VM again. Confirm the icon before you build the domain.

**Windows 11 says the PC can't run Windows 11.** The VM is powered off, EFI is on, TPM is 2.0, Secure Boot is on, processors are 2, and RAM is 4096 MB. OS type is Windows 11 (64-bit). You are on VirtualBox 7.2.2 or later. Reset Secure Boot keys to default if the button is there, then start the install again.

**The guest has no network during setup.** Adapter 1 is enabled and attached to `LabNAT`, and the NAT Network DHCP server is still enabled. A cable-unplugged icon means the adapter is disabled or the NAT Network is disabled.

**Guest Additions ISO is missing.** Mount `C:\Program Files\Oracle\VirtualBox\VBoxGuestAdditions.iso` from Devices > Optical Drives.

**You accidentally chose Bridged.** Power off. Settings > Network > Adapter 1 > NAT Network > `LabNAT`. If this happens after Windows DHCP is installed, do not start that guest while it is bridged. Unauthorize DHCP first. Phase 2 has that warning again. It should not come up if Bridged is never selected.

**E: is not where the disk landed.** VirtualBox Manager shows the VM location under the VM details. Moving a VM is Machine > Move, with the VM powered off. Do not copy a `.vdi` by hand while a snapshot exists.
