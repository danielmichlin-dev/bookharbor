# Windows and PowerShell setup

The repository is already published and the initial installation is verified. For
an existing installation, follow README.md's update/download commands and preserve
the same signing account and app identifier without uninstalling. The initial
repository-creation steps below are historical setup instructions; do not recreate
the existing repository or reinitialize Git for an update.

## 1. Extract the project

Download BookHarbor-Starter.zip and extract it. Open PowerShell in the resulting
BookHarbor folder. Confirm README.md, project.yml, Sources, scripts, and the hidden
.github and .gitignore entries are present.

Install Git, GitHub CLI, and Python if they are not already installed. Check:

```powershell
git --version
gh --version
python --version
```

## 2. Review before publication

Keep personal files outside this directory. Run:

```powershell
python scripts/privacy_check.py
Get-ChildItem -Recurse -Force
```

Review the file list and contents. The scanner catches selected common patterns, not
all possible private information. Do not add credentials to the app source, build
workflow, GitHub issues, screenshots, or build logs. No runtime credentials are needed
to compile this starter.

Before your first commit, use the exact GitHub-provided noreply address from
GitHub Settings > Emails if you do not want your normal email public. Commit author
names and emails are public metadata and are not hidden by .gitignore or the scanner.
Set the author name you want public. This is local repository configuration, not a file.

```powershell
git init -b main
git config user.name "YOUR_PUBLIC_AUTHOR_NAME"
git config user.email "YOUR_GITHUB_NOREPLY_ADDRESS"
git add .gitignore .github project.yml Sources scripts README.md WINDOWS_SETUP.md PRIVACY.md AGENTS.md
git diff --cached --stat
git diff --cached
```

Replace both placeholder values above first. After reviewing staged contents:

```powershell
git commit -m "Add native offline audiobook starter"
python scripts/privacy_check.py --history
```

Stop if any command fails. The history scan must pass before pushing. Do not bypass
a finding simply by adding a file to .gitignore; existing commits may still contain it.

## 3. Create the public repository

Sign in through GitHub CLI's browser flow. The following creates a PUBLIC repository
and uploads the committed source. Run only after the preceding review:

```powershell
gh auth login
gh repo create bookharbor --public --source . --remote origin --push
gh browse --actions
```

If the repository name is already taken, choose another name; do not overwrite an
existing project. Use standard hosted runners only. In GitHub billing, enforce a $0
budget with usage stopping at the limit for chargeable Actions/storage usage. Confirm
the budget behavior for your account before enabling chargeable services. This
workflow has a 20-minute timeout and keeps the unsigned build artifact for one day.
Public standard macOS runner compute is free; artifact storage has separate limits.

## 4. Download and install

In GitHub Actions, open the successful 'Build iPhone starter' run. Download the
BookHarbor-unsigned artifact and extract BookHarbor-unsigned.ipa.

Download Sideloadly only from https://sideloadly.io/ and follow its current Windows
instructions for Apple device drivers. Connect the iPhone using USB, trust the PC,
choose the IPA and enter your free Apple account locally in Sideloadly. Enable
Developer Mode on the phone if prompted. Follow the device prompts to trust your
own development profile. Do not paste your Apple password into chat or GitHub.

The IPA is intentionally unsigned. It cannot be installed by tapping it in Files;
Sideloadly signs it for your device. No TestFlight subscription or paid Apple
membership is part of this workflow. Keep the same bundle identifier and Apple
account for updates. Enable automatic refresh and configure Wi-Fi pairing according
to Sideloadly's documentation. The PC and phone need to be reachable for refresh.

Free signing expires after seven days. Refresh before long offline trips. Do not
uninstall to refresh: uninstalling removes books and progress. Keep your originals
outside the app. The app does not yet export its local listening history.

## 5. First test and next development session

Use README.md's acceptance checklist. To continue in Codex, open PowerShell in this
project folder and run your existing Codex command. AGENTS.md records the scope,
privacy rules, and requirement to provide progress updates with realistic estimates.

If a build fails, share the compiler error after removing any personal data. Do not
share tokens, passwords, or entire diagnostic dumps.
