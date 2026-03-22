# Taps
tap "alajmo/mani"
tap "appfolio/tap"
tap "atlassian/acli"
tap "hashicorp/tap"
tap "homebrew/bundle"
tap "homebrew/services"
tap "localstack/tap"
tap "mike-engel/jwt-cli"
tap "mutagen-io/mutagen"
tap "nikitabobko/tap"
tap "theseal/ssh-askpass"

# Core tools
brew "coreutils"
brew "git"
brew "git-absorb"
brew "git-delta"
brew "git-lfs"
brew "gh"
brew "ripgrep"
brew "fzf"
brew "jq"
brew "yq"
brew "sd"
brew "ast-grep"
brew "difftastic"
brew "comby"
brew "shellcheck"
brew "tree"
brew "pv"
brew "wget"
brew "rsync"
brew "hyperfine"
brew "watchexec"
brew "scc"
brew "eza"
brew "lnav"

# Shell
brew "starship"
brew "zoxide"
brew "zsh-completions"
brew "zsh-history-substring-search"

# Version management
brew "mise"

# Languages & runtimes
brew "go"
brew "python@3.12"
brew "openssl@3"
brew "libyaml"

# Node
brew "pnpm"

# Ruby
brew "foreman"

# Infra / cloud
brew "awscli"
brew "aws-es-proxy"
brew "kubernetes-cli"
brew "hashicorp/tap/vault"
brew "localstack/tap/localstack-cli"

# Containers & Docker
brew "docker"
brew "docker-buildx"
brew "docker-compose"
brew "docker-credential-helper"
brew "lazydocker"
brew "dive"
brew "qemu"

# AppFolio-specific
brew "appfolio/tap/percona-server@5.7", link: true
brew "appfolio/tap/solr@4.10"
brew "atlassian/acli/acli"
brew "beads"
brew "rtk"
brew "alajmo/mani/mani"
brew "mutagen-io/mutagen/mutagen-compose"

# DB / services
brew "memcached", restart_service: :changed
brew "rabbitmq", restart_service: :changed

# Other dev tools
brew "act"
brew "bazelisk"
brew "circleci"
brew "gnupg"
brew "pinentry-mac"
brew "terminal-notifier"
brew "vale"
brew "lazygit"
brew "imagemagick"
brew "pipx"
brew "mockery"
brew "neovim"
brew "openapi-generator"
brew "repo"
brew "mike-engel/jwt-cli/jwt-cli"
brew "theseal/ssh-askpass/ssh-askpass"

# Go tools (installed via brew bundle)
go "github.com/go-delve/delve/cmd/dlv"
go "github.com/golangci/golangci-lint/cmd/golangci-lint"
go "github.com/fatih/gomodifytags"
go "github.com/haya14busa/goplay/cmd/goplay"
go "golang.org/x/tools/gopls"
go "github.com/cweill/gotests/gotests"
go "github.com/josharian/impl"
go "honnef.co/go/tools/cmd/staticcheck"

# Apps
cask "1password"
cask "1password-cli"
cask "aerospace"
cask "claude-code"
cask "firefox"
cask "ghostty"
cask "github"
cask "karabiner-elements"
cask "postman"
cask "visual-studio-code"

# Review: do you still need these?
# cask "rio"          # terminal emulator (have ghostty)
# cask "warp"         # terminal emulator (have ghostty)
# cask "wezterm"      # terminal emulator (have ghostty)
# cask "rubymine"     # JetBrains Ruby IDE (have VSCode)
# cask "zed"          # editor (have VSCode + nvim)
# cask "prince"       # commercial PDF generator
# cask "xquartz"      # X11 for macOS - needed?
# brew "go@1.20"      # old Go version - mise handles this now
# brew "python@3.11"  # old Python - mise handles this now
# brew "openssl@1.1"  # old OpenSSL - needed by anything?
# brew "bazel"        # you have bazelisk which manages bazel versions
# brew "erlang"       # needed? (was a dep of something)
# brew "swig"         # needed?
# brew "docutils"     # needed?
# brew "geckodriver"  # Firefox WebDriver - still doing Playwright/Selenium?
