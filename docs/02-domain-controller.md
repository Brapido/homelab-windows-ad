# Phase 2 — Domain controller

> **Status: not done.** This is the runbook for DC01. The forest has not been created. The commands in the checks section are what to run later. They are not output from a promotion that already happened.

DC01 becomes the first domain controller of a new forest, `lab.local`, and it hosts DNS and DHCP for `LabNAT`. The repeatable work is in `scripts/`. The Server Manager clicks are described so the same choices are recognizable. Promote the server once. If you use the wizard, do not also run the promotion half of `02-Install-ADDSForest.ps1`. A second run of that script, after the server is already a domain controller for `lab.local`, only checks DNS forwarders and the reverse zone.

Related pages: [README](../README.md), [Phase 1 VirtualBox](01-virtualbox-setup.md).

## Before you start

Phase 1 is finished: DC01 is Windows Server 2022 with the desktop, Guest Additions are installed, the adapter is NAT Network `LabNAT`, and a powered-off snapshot `01-os-installed` exists. VirtualBox DHCP on `LabNAT` is still **on** at the start of this page, because you need internet once more. It goes off before Windows DHCP.

You will need:

- The Administrator password you typed at Windows setup. It is not in this repository.
- A second password you will invent for Directory Services Restore Mode. It is not the sign-in password. You will type it when the script or the wizard asks. You will not store it in git, in the VM notes, or in a screenshot.
- This repository copied onto DC01. Do that while the guest still has working internet. After the static DNS server is set to DC01 itself, outside names do not resolve until the forwarders exist.

From the guest, with VirtualBox DHCP still handing out an address:

```powershell
git clone <the-url-of-this-repository>
```

A shared folder or a copied zip is fine too. Do not point a shared folder at a profile that holds personal files. The repo has no secrets.

Set the time zone to your local time zone. Confirm the clock is within a minute of the host. Kerberos rejects tickets when the skew is more than five minutes.

Leave Windows Firewall on. AD DS, DNS, and DHCP add their own rules. Turning the firewall off hides mistakes and is not part of this lab.

## Install Windows Server 2022 Desktop Experience

Do this from the VirtualBox window on the first boot, if Phase 1 did not already land you at the desktop.

1. Start DC01. If it does not boot the ISO, attach the Server 2022 evaluation ISO under Settings > Storage and reset the VM.
2. Language, time format, and keyboard. Next.
3. Install now.
4. "I don't have a product key".
5. Select **Windows Server 2022 Standard Evaluation (Desktop Experience)**. Read both lines. The line without Desktop Experience is Server Core.
6. Accept the license.
7. Custom: Install Windows only.
8. Select the unallocated 60 GB disk. Next.
9. Setup copies files and reboots. Do not press a key to boot the ISO again. If it loops back into setup, shut down, remove the ISO from the virtual optical drive, and start from the hard disk.
10. At the customization screen, type an Administrator password and confirm it. Use something you do not use on a personal account. Do not reuse it as the DSRM password if you can avoid it, so a screenshot or a later reset does not mix the two up. Do not write it into this repo.
11. Sign in. Server Manager opens. Leave IE Enhanced Security Configuration alone. Edge is enough for the rare download.

> TODO: add screenshot
>
> `docs/screenshots/server-edition.png`
>
> The edition list with Standard Evaluation (Desktop Experience) selected. Take it during setup. It cannot be taken after the install finishes.

Then:

1. Set the time zone.
2. Settings or Server Manager: install Windows updates. Reboot until no updates remain.
3. Install Guest Additions if you did not in Phase 1. Reboot.
4. Shut down. Take snapshot `01-os-installed` if you did not already.

## Copy the repo, then turn VirtualBox DHCP off

1. Start DC01 and confirm it has an address from VirtualBox, not a `169.254` address. `ipconfig` is enough.
2. Clone or copy this repository onto the guest, for example `C:\homelab`.
3. Shut DC01 down.
4. On the host, open Network Manager, edit `LabNAT`, and clear Supports DHCP / Enable DHCP. Or:

```text
VBoxManage natnetwork modify --netname LabNAT --dhcp off
VBoxManage list natnetworks
```

5. Read `VBoxManage list natnetworks` and write down the gateway if it is not `10.0.10.1`.
6. Start DC01. It will not get a DHCP address now. That is the point. The next script sets `10.0.10.10`.

From here on, do the work from the VirtualBox console. If you change the IP of an adapter you are remoted in on, that session drops.

## Rename the server and set the static IP

Open an elevated Windows PowerShell window. The blue "Windows PowerShell" shortcut, not PowerShell 7. The AD and DHCP modules this lab uses are the Windows PowerShell 5.1 modules.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
cd C:\homelab
.\scripts\01-Set-ServerBasics.ps1 -WhatIf
.\scripts\01-Set-ServerBasics.ps1 -Restart
```

`-WhatIf` prints the change and does not apply it. The real run sets:

| Setting | Value |
| --- | --- |
| Computer name | `DC01` |
| Address | `10.0.10.10/24` |
| Gateway | `10.0.10.1`, or whatever `list natnetworks` showed |
| DNS | `10.0.10.10` |

The script refuses a public DNS server on the adapter. `1.1.1.1` and `8.8.8.8` are forwarders, added after promotion, not adapter DNS servers.

`-Restart` reboots if the new name is not active yet. An IP change does not need a reboot. A rename does. If you omit `-Restart`, reboot yourself before you promote. Promoting a computer that is still `WIN-...` until the next boot is a mess.

After the reboot, sign in and confirm. These are checks, not a transcript from a finished lab:

```powershell
hostname
Get-NetIPAddress -AddressFamily IPv4
Get-DnsClientServerAddress -AddressFamily IPv4
Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, Dhcp
```

What you want to see:

- The active name is `DC01`.
- `10.0.10.10` with prefix 24 is on the adapter.
- DHCP for IPv4 on that adapter is Disabled.
- The only DNS server is `10.0.10.10`.

Internet names will not resolve yet. `ping 1.1.1.1` can still work, because that does not need DNS. `Resolve-DnsName microsoft.com` failing until the forwarders exist is expected.

Shut down and take snapshot `02-static-ip-workgroup` if you want a rewind point before promotion.

> TODO: add screenshot
>
> `docs/screenshots/dc01-ipconfig.png`
>
> `ipconfig /all` showing `10.0.10.10/24` and DNS `10.0.10.10`. Crop it so nothing else sensitive is in the frame.

The same settings exist in the GUI: System Properties for the computer name, and the adapter's IPv4 properties for the address. Use one path. The script is the one this repo will rerun.

## Promote DC01 to a new forest

### Script path

Elevated Windows PowerShell, still in the repo:

```powershell
.\scripts\02-Install-ADDSForest.ps1 -WhatIf
.\scripts\02-Install-ADDSForest.ps1
```

`-WhatIf` does not ask for a password and does not install the role.

The real run:

1. Installs AD DS and the management tools if they are missing.
2. Asks for the DSRM password twice, with `Read-Host -AsSecureString`. Nothing is written to the repo. The characters are not a script parameter, so they do not sit in the command line.
3. Creates forest `lab.local`, NetBIOS name `LAB`, functional level Windows Server 2016. The cmdlet name for that level is `WinThreshold`. There is no "Windows Server 2022" functional level.
4. Installs DNS and does not try to create a delegation. `lab.local` has no parent zone. The delegation warning in the GUI is the same fact. It is expected.
5. Sets forwarders `1.1.1.1` and `8.8.8.8` and creates the `10.0.10.0/24` reverse lookup zone, best effort, before reboot.
6. Reboots after 15 seconds. Press Ctrl+C during that wait if you need to stop it. Pass `-NoReboot` if you want to reboot yourself. The domain controller is not finished until it reboots.

Database, logs, and SYSVOL stay on the defaults: `C:\Windows\NTDS` and `C:\Windows\SYSVOL`.

If you want the other forest name, decide now. You cannot rename it later without rebuilding.

```powershell
.\scripts\02-Install-ADDSForest.ps1 -DomainName corp.homelab.local
```

The NetBIOS name becomes `CORP` unless you also pass `-DomainNetbiosName`. The rest of this repo assumes `lab.local` and `LAB`. If you change the name, pass `-DomainName` to scripts 03, 04, and 05 as well.

### GUI path, if you would rather click once

Server Manager > Manage > Add Roles and Features > Role-based > this server > Active Directory Domain Services > add the management tools > install. Then the notification flag > Promote this server to a domain controller.

| Wizard page | Choice |
| --- | --- |
| Deployment | Add a new forest. Root domain name `lab.local`. |
| Domain controller options | Forest and domain functional level: Windows Server 2016. DNS is checked. Type the DSRM password. |
| DNS options | The delegation warning is expected. Continue. |
| Additional options | NetBIOS domain name `LAB`. |
| Paths | Leave the defaults. |
| Review | Read it. Install. The server reboots. |

Do not run the script's promotion after the wizard has already promoted the server. Running the script afterward is safe: it sees an existing domain controller for `lab.local` and only checks forwarders and the reverse zone.

### What you sign in with after the reboot

Sign in as `LAB\Administrator`.

The password is the Administrator password from Windows setup, not the DSRM password. The local Administrator account becomes the domain Administrator. The DSRM password is only for Directory Services Restore Mode, which you reach from the boot menu when you are restoring the directory. Using the DSRM password at the normal sign-in screen will not work, and that feels like a lockout the first time you see it.

> TODO: add screenshot
>
> `docs/screenshots/promotion.png`
>
> The sign-in screen or System Properties showing the domain `lab.local`, after the reboot. Do not include a password.

## DNS

After the reboot, elevated PowerShell. If script 02 warned that forwarders or the reverse zone were not created before the reboot, run it again. It will not try to promote a second time.

```powershell
.\scripts\02-Install-ADDSForest.ps1
```

Checks to run yourself:

```powershell
Get-ADDomain
Get-ADDomainController
Resolve-DnsName lab.local
Resolve-DnsName dc01.lab.local
Resolve-DnsName 10.0.10.10
Get-DnsServerZone
Get-DnsServerForwarder
net share
dcdiag /test:dns
```

What a healthy result looks like, described without pretending this lab already produced it:

- `Get-ADDomain` shows DNS root `lab.local` and a Windows Server 2016 functional level.
- `Resolve-DnsName lab.local` and `Resolve-DnsName dc01.lab.local` return `10.0.10.10`.
- `Resolve-DnsName 10.0.10.10` returns `dc01.lab.local` once the reverse zone and the PTR exist. If the PTR is missing, run `ipconfig /registerdns` and check again.
- `Get-DnsServerZone` lists `lab.local` and `10.0.10.in-addr.arpa`.
- `Get-DnsServerForwarder` lists `1.1.1.1` and `8.8.8.8`.
- `net share` lists `NETLOGON` and `SYSVOL`.
- `dcdiag /test:dns` is mostly passing. A brand-new domain controller often reports a root-hints or event-log complaint on the first run. Read it. A failure that says the server is not advertising, or that the forward zone is missing, is a real problem. The log is `C:\Windows\debug\dcpromo.log`.

Outside names should work after the forwarders are set:

```powershell
Resolve-DnsName microsoft.com
```

That query should go to a forwarder and return addresses. If it does not, check the forwarders and check that the NAT gateway still routes. Do not "fix" it by adding `8.8.8.8` to the adapter.

> TODO: add screenshot
>
> `docs/screenshots/dns-zones.png`
>
> DNS Manager, or the `Get-DnsServerZone` list, showing `lab.local` and the reverse zone.

Shut down and take snapshot `03-domain-controller` when those checks look right.

## DHCP

Two DHCP servers on `LabNAT` will both answer. Confirm VirtualBox DHCP is still off, then run the Windows DHCP script. The switch is your confirmation. The guest cannot see the host's VirtualBox setting.

```powershell
.\scripts\03-Configure-DHCP.ps1 -WhatIf -IConfirmVirtualBoxDhcpIsOff
.\scripts\03-Configure-DHCP.ps1 -IConfirmVirtualBoxDhcpIsOff
```

The script:

1. Installs the DHCP role if it is missing.
2. Creates the local DHCP Administrators and DHCP Users groups if they are missing, and restarts the DHCP service.
3. Clears the Server Manager post-install reminder. That reminder is not the same thing as authorization.
4. Authorizes `DC01.lab.local` at `10.0.10.10` in Active Directory. An unauthorized DHCP server in a domain shows a red mark and does not hand out leases.
5. Creates scope `Lab Clients` on `10.0.10.0`, range `10.0.10.100`–`10.0.10.200`, mask `255.255.255.0`, 8-day lease, state Active.
6. Sets option 003 router `10.0.10.1`, option 006 DNS `10.0.10.10`, and option 015 DNS domain name `lab.local`.
7. Sets one conflict-detection attempt.
8. Ensures the reverse zone and the forwarders exist if script 02 did not finish that part.

It does not delete a scope. If `10.0.10.0` already exists with a different range, it warns and leaves the range alone.

Checks:

```powershell
Get-DhcpServerInDC
Get-DhcpServerv4Scope -ScopeId 10.0.10.0
Get-DhcpServerv4OptionValue -ScopeId 10.0.10.0
```

What you want: the server is authorized, the scope is Active, the range is `.100` through `.200`, and the three options match the table in the README. CLIENT01 is not expected to have a lease yet. That is Phase 3. You can confirm the service is running with `Get-Service DHCPServer`.

In the DHCP console the same picture is: the server has no red down arrow, IPv4 > Scope [10.0.10.0] Lab Clients is active, and Scope Options shows 003, 006, and 015.

> TODO: add screenshot
>
> `docs/screenshots/dhcp-scope.png`
>
> The active scope and the three options. The server name should show authorized.

Also confirm, on the host, that no VM adapter was switched to Bridged while you did this. `VBoxManage showvminfo DC01` includes the attachment. It should mention the NAT Network, not Bridged.

## OUs and users

```powershell
.\scripts\04-New-LabOUs.ps1 -WhatIf
.\scripts\04-New-LabOUs.ps1
.\scripts\05-New-LabUsers.ps1 -WhatIf
.\scripts\05-New-LabUsers.ps1
```

Script 04 creates `Company` and, under it, `IT`, `HR`, `Lab Operations`, and `Finance`. Each of those has `Users`, `Computers`, and `Groups`. New OUs are protected from accidental deletion. Each department gets a global security group in its Groups OU: `IT`, `HR`, `LabOperations`, and `Finance`.

Script 05 reads `data\lab-users.csv`. It checks every row before it creates anyone. It asks once for an initial password and applies that password to new accounts only. Each new account is enabled and must change the password at next logon. Accounts that already exist are skipped, and their passwords are not reset. Missing group membership is added.

Run script 05 a second time when the first run succeeds. The second run should report that the users already exist and that the memberships are already present. That is the idempotent check in the Phase 2 list. It is not done until you have seen it.

The twelve people are fictional. Do not replace the CSV with real names. Do not put the password in a screenshot of the PowerShell window. `Read-Host -AsSecureString` hides what you type; a later `Get-ADUser` screenshot is the one to keep.

```powershell
Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName
Get-ADUser -Filter * -SearchBase (Get-ADDomain).DistinguishedName -Properties Department, Title |
    Where-Object { $_.DistinguishedName -like '*OU=Company,*' } |
    Select-Object Name, SamAccountName, Department, Title
Get-ADGroup -Filter * -SearchBase (Get-ADDomain).DistinguishedName |
    Where-Object { $_.DistinguishedName -like '*OU=Groups,*' } |
    Select-Object Name, SamAccountName
```

What you want: four department OUs, twelve users in the department Users OUs, and four department groups. The built-in `CN=Users` container will still contain the default domain groups and Administrator. The fictional users should not be in that container.

> TODO: add screenshot
>
> `docs/screenshots/ou-tree.png`
>
> Active Directory Users and Computers expanded under Company.

> TODO: add screenshot
>
> `docs/screenshots/lab-users.png`
>
> One department's Users OU. No password field, no password-reset dialog.

New computers still go to the built-in Computers container. Moving CLIENT01, or changing that default with `redircmp`, is Phase 3. Do not join the client in this phase unless you are ready to write those notes.

Shut down DC01 and take snapshot `04-ou-and-users`.

## Troubleshooting

**The promotion wizard says it cannot create a DNS delegation.** Expected for a new forest named `lab.local`. There is no parent zone to publish a delegation in. Continue. The script sets `-CreateDnsDelegation $false` for the same reason.

**Promotion says the computer has a dynamic IP, or the name is still `WIN-...`.** Reboot if a rename is pending, then rerun `01-Set-ServerBasics.ps1`. Script 02 will not promote until the active name is `DC01` and `10.0.10.10` is static.

**The DSRM password is rejected.** The domain complexity rules apply: length, and characters from enough categories. The script also refuses fewer than 8 characters before it calls the promotion. Nothing was saved. Run it again and pick a stronger password. Do not put the password in the script to "make it work".

**You cannot sign in after the reboot.** Use `LAB\Administrator` and the Windows setup password. The DSRM password will not sign you in at this screen. If the name `LAB` is wrong because you chose another NetBIOS name, use that name. The account is not a Microsoft account.

**`NETLOGON` or `SYSVOL` is missing from `net share`.** Wait a few minutes after the first reboot and check again. The Netlogon service and DFS Replication should be running. Server 2022 uses DFSR for a new forest. If they are still missing after a clean reboot, read `C:\Windows\debug\dcpromo.log` before you promote again. Restoring snapshot `02-static-ip-workgroup` is the clean retry if promotion failed halfway. Do not restore a post-promotion snapshot and a pre-promotion snapshot in a mix once a client exists. No client exists yet.

**DNS lookups for the domain fail.** The adapter DNS server must be `10.0.10.10` and nothing else. A public resolver on the adapter is the usual cause. `Get-DnsClientServerAddress` shows it.

**Outside names fail, domain names work.** Forwarders are missing or the NAT gateway is wrong. `Get-DnsServerForwarder` and `Get-NetRoute -DestinationPrefix 0.0.0.0/0`. Fix the forwarders. Do not add a public DNS server to the NIC.

**DHCP shows a red mark, or clients later get `169.254` addresses.** The server is not authorized, the scope is not active, or the service is stopped. `Get-DhcpServerInDC` and `Get-Service DHCPServer`. Also confirm VirtualBox DHCP is off and the adapter is still `LabNAT`. In the DHCP console, the server bindings should include `10.0.10.10` (the server node, Add/Remove Bindings).

**Both VirtualBox and Windows are offering addresses.** Turn VirtualBox DHCP off, release and renew the client later, and confirm only DC01 is authorized. Do not fix this by switching the VM to Bridged.

**Script execution policy blocks the file.** `Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned` applies to that window only. Do not set the machine policy to Unrestricted.

**A rerun of script 05 changed a password.** It should not. Existing users are skipped. If you saw a password prompt and then "already exists", the prompt means at least one row was new. Read the per-user lines. If an existing account's password changed, stop and treat that as a bug in the script rather than running it again.

**Time is wrong and logons fail with a clock error.** Fix the host clock. In the guest, Guest Additions time sync should catch up. On a single domain controller, the guest following the host is the lab design. A production PDC emulator would sync to an external NTP source. This lab does not need that extra service yet.

**You want to undo the whole promotion.** Shut down, restore snapshot `02-static-ip-workgroup`, and start again. That is why the snapshot exists.
