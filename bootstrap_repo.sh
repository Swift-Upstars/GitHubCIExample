#!/usr/bin/env bash
set -euo pipefail

TARGET_REPO="${1:-}"
[[ -n "$TARGET_REPO" ]] || {
  echo "❌ Укажи ORG/REPO. Пример: ./bootstrap_repo.sh Swift-Upstars/CityPuzzleTime"
  exit 1
}

[[ "$TARGET_REPO" == */* ]] || {
  echo "❌ Укажи repo в формате ORG/REPO. Пример: Swift-Upstars/CityPuzzleTime"
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }; }
need git
need gh
need base64
need sed
need head
need ls
need find

if [[ ! -d ".git" ]]; then
  echo "ℹ️ Git repo не найден. Инициализирую..."
  git init . >/dev/null 2>&1
fi

ORIG_TARGET_REPO="$TARGET_REPO"
ORG="${TARGET_REPO%%/*}"
REPO_NAME="${TARGET_REPO#*/}"

SAFE_REPO_NAME="$(echo "$REPO_NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[[:space:]]+/-/g; s/[^a-z0-9._-]//g')"

TARGET_REPO="${ORG}/${SAFE_REPO_NAME}"

if [[ "$ORIG_TARGET_REPO" != "$TARGET_REPO" ]]; then
  echo "⚠️ Repo name normalized:"
  echo "   '$ORIG_TARGET_REPO' → '$TARGET_REPO'"
fi

# =============================
# ✅ PROJECT CONFIG
# =============================

SCHEME_NAME="MyNewApp"
APP_IDENTIFIER="com.example.mynewapp"
TEAM_ID="ABCDE12345"

PROJECT="MyNewApp.xcodeproj"

UPLOAD_MODE="testflight"
SUBMIT_FOR_REVIEW="false"

MATCH_GIT_TOKEN="github_pat_example1234567890"
MATCH_PASSWORD="example_match_password"

ASC_KEY_ID="ABC123DEFG"
ASC_ISSUER_ID="11111111-2222-3333-4444-555555555555"

KEYCHAIN_PASSWORD="example_keychain_password"

ASC_KEY_P8_BASE64="BASE64_ENCODED_P8_KEY_STRING"
ASC_KEY_P8_PATH="AuthKey_ABC123DEFG.p8"

# =============================
# ✅ END PROJECT CONFIG
# =============================

if [[ -z "${ASC_KEY_P8_BASE64:-}" ]]; then
  [[ -f "$ASC_KEY_P8_PATH" ]] || { echo "❌ Не найден p8 файл: $ASC_KEY_P8_PATH"; exit 1; }
  ASC_KEY_P8_BASE64="$(base64 -i "$ASC_KEY_P8_PATH" | tr -d '\n')"
fi

export SCHEME_NAME
export APP_IDENTIFIER
export TEAM_ID
export PROJECT
export MATCH_GIT_TOKEN
export MATCH_PASSWORD
export ASC_KEY_ID
export ASC_ISSUER_ID
export ASC_KEY_P8_BASE64
export KEYCHAIN_PASSWORD
export UPLOAD_MODE
export SUBMIT_FOR_REVIEW

req() { [[ -n "${!1:-}" ]] || { echo "❌ $1 пустой"; exit 1; }; }

req MATCH_GIT_TOKEN
req MATCH_PASSWORD
req ASC_KEY_ID
req ASC_ISSUER_ID
req ASC_KEY_P8_BASE64

[[ -d "$PROJECT" ]] || { echo "❌ PROJECT не найден: $PROJECT"; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
  echo "🔐 gh не авторизован. Запускаю: gh auth login"
  gh auth login
fi

echo "✅ gh auth OK"

MATCH_REPO_NAME="ios-certificates-${TEAM_ID}"
MATCH_REPO_FULL="${ORG}/${MATCH_REPO_NAME}"

echo "🔧 Preparing match repo: $MATCH_REPO_FULL"

if ! gh repo view "$MATCH_REPO_FULL" >/dev/null 2>&1; then
  echo "🆕 Creating new match repo $MATCH_REPO_FULL private..."
  gh repo create "$MATCH_REPO_FULL" --private --confirm
else
  echo "ℹ️ Match repo already exists: $MATCH_REPO_FULL"
fi

MATCH_GIT_URL="https://github.com/${MATCH_REPO_FULL}.git"
export MATCH_GIT_URL

echo "✅ MATCH_GIT_URL set to: $MATCH_GIT_URL"

if ! gh repo view "$TARGET_REPO" >/dev/null 2>&1; then
  echo "🆕 Создаю приватный repo $TARGET_REPO"
  gh repo create "$TARGET_REPO" --private --confirm
fi

REMOTE_SSH="git@github.com:${TARGET_REPO}.git"
git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_SSH"

mkdir -p .github/workflows

cat > .github/workflows/ios.yml <<'YAML'
name: iOS Build (Private CI)

on:
  push:
    branches: [ main ]
  workflow_dispatch:
    inputs:
      upload_mode:
        description: "testflight or appstore"
        required: true
        default: "testflight"

jobs:
  build:
    runs-on: macos-15
    timeout-minutes: 90

    env:
      SCHEME_NAME: ${{ vars.SCHEME_NAME }}
      APP_IDENTIFIER: ${{ vars.APP_IDENTIFIER }}
      TEAM_ID: ${{ vars.TEAM_ID }}
      MATCH_GIT_URL: ${{ vars.MATCH_GIT_URL }}
      PROJECT: ${{ vars.PROJECT }}
      UPLOAD_MODE: ${{ github.event.inputs.upload_mode || 'testflight' }}
      SUBMIT_FOR_REVIEW: "false"

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Verify Xcode
        run: xcodebuild -version

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.2"
          bundler-cache: false

      - name: Run ship.sh
        env:
          MATCH_GIT_TOKEN: ${{ secrets.MATCH_GIT_TOKEN }}
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          chmod +x ship.sh
          ./ship.sh
YAML

cat > ship.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

die() { echo "❌ $*" >&2; exit 1; }

trim_quotes_and_spaces() {
  local s
  s="$(echo "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ "$s" == \"*\" && "$s" == *\" ]]; then s="${s:1:${#s}-2}"; fi
  if [[ "$s" == \'*\' && "$s" == *\' ]]; then s="${s:1:${#s}-2}"; fi
  [[ "$s" == "\"\"" || "$s" == "''" ]] && s=""
  echo "$s"
}

: "${SCHEME_NAME:?SCHEME_NAME пустой}"
: "${APP_IDENTIFIER:?APP_IDENTIFIER пустой}"
: "${TEAM_ID:?TEAM_ID пустой}"
: "${MATCH_GIT_URL:?MATCH_GIT_URL пустой}"
: "${MATCH_GIT_TOKEN:?MATCH_GIT_TOKEN пустой}"
: "${MATCH_PASSWORD:?MATCH_PASSWORD пустой}"
: "${ASC_KEY_ID:?ASC_KEY_ID пустой}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID пустой}"
: "${ASC_KEY_P8_BASE64:?ASC_KEY_P8_BASE64 пустой}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD пустой}"

PROJECT="$(trim_quotes_and_spaces "${PROJECT:-}")"

if [[ -z "$PROJECT" || "$PROJECT" == "null" ]]; then
  pr_file="$(ls -1 *.xcodeproj 2>/dev/null | head -n1 || true)"
  [[ -n "$pr_file" ]] || die "Не найден *.xcodeproj в корне"
  PROJECT="$pr_file"
fi

[[ "$PROJECT" == *.xcodeproj ]] || die "PROJECT должен заканчиваться на .xcodeproj"
[[ -d "$PROJECT" ]] || die "PROJECT не найден: $PROJECT"

mkdir -p .asc_key
ASC_KEY_FILE="$PWD/.asc_key/AuthKey.p8"
echo "$ASC_KEY_P8_BASE64" | base64 --decode > "$ASC_KEY_FILE"
chmod 600 "$ASC_KEY_FILE"

if ! command -v bundle >/dev/null 2>&1; then
  gem install bundler --no-document
fi

cat > Gemfile <<'GEM'
source "https://rubygems.org"
gem "fastlane", "~> 2.232"
GEM

bundle config set path 'vendor/bundle' >/dev/null 2>&1 || true
bundle install --jobs 4 --retry 3

mkdir -p fastlane

cat > fastlane/Appfile <<APP
app_identifier("$APP_IDENTIFIER")
team_id("$TEAM_ID")
APP

cat > fastlane/Fastfile <<'RUBY'
default_platform(:ios)
require "base64"

platform :ios do
  lane :ship do
    api_key = app_store_connect_api_key(
      key_id: ENV["ASC_KEY_ID"],
      issuer_id: ENV["ASC_ISSUER_ID"],
      key_filepath: ENV["ASC_KEY_FILEPATH"],
      duration: 1200
    )

    keychain_name = "fastlane_tmp.keychain"

    create_keychain(
      name: keychain_name,
      password: ENV["KEYCHAIN_PASSWORD"],
      default_keychain: true,
      unlock: true,
      timeout: 3600,
      add_to_search_list: true
    )

    basic = Base64.strict_encode64("x-access-token:#{ENV['MATCH_GIT_TOKEN']}")
    app_id = ENV["APP_IDENTIFIER"]
    fixed_profile_name = "match AppStore #{app_id}"

    match(
      type: "appstore",
      git_url: ENV["MATCH_GIT_URL"],
      api_key: api_key,
      readonly: false,
      force: false,
      profile_name: fixed_profile_name,
      keychain_name: keychain_name,
      keychain_password: ENV["KEYCHAIN_PASSWORD"],
      git_basic_authorization: basic
    )

    mapping = lane_context[SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING] || {}
    profile_name = mapping[app_id] || fixed_profile_name

    UI.user_error!("match не вернул provisioning profile mapping") if profile_name.to_s.empty?

    update_code_signing_settings(
      use_automatic_signing: false,
      path: ENV["PROJECT"],
      team_id: ENV["TEAM_ID"],
      targets: [ENV["SCHEME_NAME"]],
      build_configurations: ["Release"],
      code_sign_identity: "Apple Distribution",
      profile_name: profile_name
    )

    export_options = {
      method: "app-store",
      signingStyle: "manual",
      teamID: ENV["TEAM_ID"],
      provisioningProfiles: { app_id => profile_name }
    }

    build_app(
      scheme: ENV["SCHEME_NAME"],
      project: ENV["PROJECT"],
      clean: true,
      configuration: "Release",
      export_method: "app-store",
      export_options: export_options,
      xcargs: "DEVELOPMENT_TEAM=#{ENV['TEAM_ID']}"
    )

    mode = ENV["UPLOAD_MODE"].to_s.strip.downcase

    if mode == "appstore"
      upload_to_app_store(
        api_key: api_key,
        submit_for_review: (ENV["SUBMIT_FOR_REVIEW"] == "true"),
        skip_metadata: true,
        skip_screenshots: true
      )
    else
      upload_to_testflight(
        api_key: api_key,
        skip_waiting_for_build_processing: true
      )
    end

    UI.success("✅ Done: #{mode}")
  ensure
    begin
      delete_keychain(name: "fastlane_tmp.keychain")
    rescue => e
      UI.message("Keychain cleanup warning: #{e}")
    end
  end
end
RUBY

export ASC_KEY_FILEPATH="$ASC_KEY_FILE"
export PROJECT="$PROJECT"

cleanup() {
  rm -rf .asc_key
  rm -rf vendor/bundle
  rm -rf .bundle
  rm -rf .fastlane
  rm -rf fastlane/report.xml
  rm -rf fastlane/README.md
  rm -rf fastlane/Preview.html
  rm -rf fastlane/screenshots
  rm -rf fastlane/test_output
}

trap cleanup EXIT

bundle exec fastlane ios ship
BASH

chmod +x ship.sh

touch .gitignore

grep -q '^bootstrap_repo.sh$' .gitignore 2>/dev/null || cat >> .gitignore <<'EOF'

# Local bootstrap script with secrets
bootstrap_repo.sh
EOF

grep -q '^\.asc_key/' .gitignore 2>/dev/null || cat >> .gitignore <<'EOF'

# CI artifacts / secrets
.asc_key/
vendor/bundle/
.bundle/
.fastlane/
fastlane/report.xml
fastlane/README.md
fastlane/Preview.html
fastlane/screenshots/
fastlane/test_output/
build/
DerivedData/
.build/
*.xcarchive
*.ipa
*.dSYM
*.dSYM.zip
*.p8
*.mobileprovision
*.cer
*.p12
*.pem
*.key
EOF

echo "🔧 Setting repo Variables..."
gh variable set SCHEME_NAME     -R "$TARGET_REPO" --body "$SCHEME_NAME"
gh variable set APP_IDENTIFIER  -R "$TARGET_REPO" --body "$APP_IDENTIFIER"
gh variable set TEAM_ID         -R "$TARGET_REPO" --body "$TEAM_ID"
gh variable set MATCH_GIT_URL   -R "$TARGET_REPO" --body "$MATCH_GIT_URL"
gh variable set PROJECT         -R "$TARGET_REPO" --body "$PROJECT"

echo "🔐 Setting repo Secrets..."
gh secret set MATCH_GIT_TOKEN     -R "$TARGET_REPO" --body "$MATCH_GIT_TOKEN"
gh secret set MATCH_PASSWORD      -R "$TARGET_REPO" --body "$MATCH_PASSWORD"
gh secret set ASC_KEY_ID          -R "$TARGET_REPO" --body "$ASC_KEY_ID"
gh secret set ASC_ISSUER_ID       -R "$TARGET_REPO" --body "$ASC_ISSUER_ID"
gh secret set ASC_KEY_P8_BASE64   -R "$TARGET_REPO" --body "$ASC_KEY_P8_BASE64"
gh secret set KEYCHAIN_PASSWORD   -R "$TARGET_REPO" --body "$KEYCHAIN_PASSWORD"

echo "🧹 Cleaning local leftovers..."

rm -rf .asc_key
rm -rf vendor/bundle
rm -rf .bundle
rm -rf .fastlane
rm -rf fastlane/report.xml
rm -rf fastlane/README.md
rm -rf fastlane/Preview.html
rm -rf fastlane/screenshots
rm -rf fastlane/test_output
rm -rf build
rm -rf DerivedData
rm -rf .build

rm -rf *.xcarchive
rm -rf *.ipa
rm -rf *.dSYM
rm -rf *.dSYM.zip

find . -name ".DS_Store" -delete
find . -name "xcuserdata" -type d -prune -exec rm -rf {} +
find . -name "*.xcuserstate" -delete
find . -name "*.xcscmblueprint" -delete
find . -name "*.xccheckout" -delete
find . -name "*.mobileprovision" -delete
find . -name "*.cer" -delete
find . -name "*.p12" -delete
find . -name "*.pem" -delete
find . -name "*.key" -delete

git add .

git reset -- "$ASC_KEY_P8_PATH" 2>/dev/null || true

git commit -m "Initial CI setup" || echo "– уже закоммичено"

git branch -M main

echo "🚀 Pushing to $TARGET_REPO ..."
git push -u origin main

echo "✅ Bootstrap done."
echo "🎉 Готово. Проверь GitHub → Actions → iOS Build (Private CI)."
