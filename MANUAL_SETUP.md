# Manual Setup Steps

These cannot be automated by dotfiles and must be done by hand on a new machine.

---

## 1. GPG Key

Your git config has GPG commit signing enabled (`commit.gpgsign = true`) with key `919959A90E7E7AB2`.

**On the old machine:**
```sh
# Export public key
gpg --armor --export 919959A90E7E7AB2 > ~/gpg-public.asc

# Export private key (keep this secure, do not put in dotfiles)
gpg --armor --export-secret-keys 919959A90E7E7AB2 > ~/gpg-private.asc
```

**On the new machine:**
```sh
# Import both keys
gpg --import ~/gpg-public.asc
gpg --import ~/gpg-private.asc

# Set ultimate trust
gpg --edit-key 919959A90E7E7AB2
# At the gpg> prompt: trust → 5 (ultimate) → quit

# Tell GitHub about the key if needed
gpg --armor --export 919959A90E7E7AB2 | pbcopy
# Paste at: github.com → Settings → SSH and GPG keys → New GPG key

# Verify
echo "test" | gpg --clearsign
```

Pinentry-mac is installed via Brewfile, but you may need to configure it:
```sh
echo "pinentry-program $(which pinentry-mac)" >> ~/.gnupg/gpg-agent.conf
gpgconf --kill gpg-agent
```

---

## 2. SSH Keys

**Do not copy your old SSH keys directly.** Best practice is to generate new ones.

```sh
# Generate new Ed25519 key
ssh-keygen -t ed25519 -C "justin.maher@appfolio.com" -f ~/.ssh/id_ed25519

# Add to ssh-agent
ssh-add ~/.ssh/id_ed25519

# Copy public key
cat ~/.ssh/id_ed25519.pub | pbcopy
```

Then add the public key to:
- **GitHub**: github.com → Settings → SSH keys → New SSH key
- **AppFolio internal systems** (check with IT/Okta setup)

---

## 3. 1Password SSH Agent (if used)

If you use 1Password's SSH agent instead of a standalone key:
1. Install 1Password (in Brewfile)
2. Sign in and unlock
3. Enable SSH agent in 1Password settings → Developer
4. Add to `~/.ssh/config`:
   ```
   Host *
     IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
   ```

---

## 4. Otto Setup

Otto generates `~/.otto/shell-extensions/.zshrc` which sets AWS credentials and other env vars. Run it first before expecting Claude/AWS tools to work:

```sh
otto up
# Follow prompts for auth
```

---

## 5. AppFolio Secrets (~/.secrets)

Re-create `~/.secrets` with your JIRA API token (get a new one from id.atlassian.com if the old one expired):

```sh
echo 'export JIRA_API_TOKEN=<your-token>' > ~/.secrets
chmod 600 ~/.secrets
```

---

## 6. Git Credential Helper

The gitconfig uses `credential.helper = store`. On first `git push` to a private repo, it will prompt and then cache credentials. For GitHub, use the `gh` CLI to auth instead:

```sh
gh auth login
```
