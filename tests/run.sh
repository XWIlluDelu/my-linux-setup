#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/my-linux-setup-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle haystack
  needle="$1"
  haystack="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local needle haystack
  needle="$1"
  haystack="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

test_result_protocol() {
  local result_log record
  result_log="$TMP_DIR/results.tsv"

  (
    source "$ROOT_DIR/lib/results.sh"
    export LINUX_SETUP_RESULT_LOG="$result_log"
    record_result shell_env failed $'line one\tline two\nline three'
    record_result cleanup updated 'done'
    bash -c 'source "$1/lib/common.sh"; record_result child_task failed child' bash "$ROOT_DIR"
    [[ "$(result_failed_count "$result_log")" == "2" ]]
  )

  record="$(head -n 1 "$result_log")"
  [[ "$record" == $'shell_env\tfailed\tline one line two line three' ]] || fail "result protocol did not normalize TSV fields"
}

test_apt_mirror_transform() {
  local source_file candidate_file content
  source_file="$TMP_DIR/debian.sources"
  candidate_file="$TMP_DIR/debian.candidate"
  cat > "$source_file" <<'EOF'
deb http://deb.debian.org/debian bookworm main
URIs: https://security.debian.org/debian-security
URIs: https://deb.debian.org/debian
EOF

  source "$ROOT_DIR/lib/common.sh"
  as_root() { "$@"; }
  source "$ROOT_DIR/lib/apt-mirror.sh"
  render_apt_mirror_candidate "$source_file" "$candidate_file" debian mirror.example
  content="$(<"$candidate_file")"

  assert_contains 'https://mirror.example/debian/ bookworm main' "$content"
  assert_contains 'https://security.debian.org/debian-security' "$content"
  assert_contains 'URIs: https://mirror.example/debian/' "$content"

  printf 'URIs: https://security.debian.org/debian-security\n' > "$source_file"
  if render_apt_mirror_candidate "$source_file" "$candidate_file" debian mirror.example 2>/dev/null; then
    fail "mirror transform accepted a source file with no replaceable distribution mirror"
  fi
}

write_mirror_fakes() {
  local fake_bin
  fake_bin="$1"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '0.001\n'
EOF
  cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
  shift
fi
exec "$@"
EOF
  cat > "$fake_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
state_file="${FAKE_APT_STATE:?}"
count=0
[[ -f "$state_file" ]] && count="$(<"$state_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$state_file"
if [[ "${FAKE_APT_FAIL_FIRST:-1}" == "1" && "$count" == "1" ]]; then
  exit 1
fi
EOF
  chmod 755 "$fake_bin/curl" "$fake_bin/sudo" "$fake_bin/apt-get"
}

test_apt_mirror_rollback() {
  local apt_root os_release fake_bin source_file original output status apt_state
  apt_root="$TMP_DIR/apt"
  os_release="$TMP_DIR/os-release"
  fake_bin="$TMP_DIR/fake-bin"
  source_file="$apt_root/sources.list"
  apt_state="$TMP_DIR/apt-update-count"
  mkdir -p "$apt_root"
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$os_release"
  printf 'deb https://mirror.old/debian bookworm main\n' > "$source_file"
  original="$(<"$source_file")"
  write_mirror_fakes "$fake_bin"

  set +e
  output="$(PATH="$fake_bin:$PATH" FAKE_APT_STATE="$apt_state" LINUX_SETUP_APT_ETC_DIR="$apt_root" LINUX_SETUP_OS_RELEASE_FILE="$os_release" bash "$ROOT_DIR/commands/maintain/mirror.sh" --apply 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "mirror command succeeded after apt metadata refresh failed"
  [[ "$(<"$source_file")" == "$original" ]] || fail "mirror command did not restore the original source file"
  [[ -f "$source_file.linux-setup.bak" ]] || fail "mirror command did not retain the original source backup"
  [[ "$(<"$apt_state")" == "2" ]] || fail "mirror command did not refresh metadata after restoring sources"
  assert_contains 'metadata was refreshed' "$output"
}

test_apt_mirror_success() {
  local apt_root os_release fake_bin source_file original output apt_state
  apt_root="$TMP_DIR/apt-success"
  os_release="$TMP_DIR/os-release-success"
  fake_bin="$TMP_DIR/fake-bin-success"
  source_file="$apt_root/sources.list"
  apt_state="$TMP_DIR/apt-success-count"
  mkdir -p "$apt_root"
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$os_release"
  printf 'deb https://mirror.old/debian bookworm main\n' > "$source_file"
  original="$(<"$source_file")"
  write_mirror_fakes "$fake_bin"

  output="$(PATH="$fake_bin:$PATH" FAKE_APT_STATE="$apt_state" FAKE_APT_FAIL_FIRST=0 LINUX_SETUP_APT_ETC_DIR="$apt_root" LINUX_SETUP_OS_RELEASE_FILE="$os_release" bash "$ROOT_DIR/commands/maintain/mirror.sh" --apply 2>&1)"

  assert_contains 'https://deb.debian.org/debian/ bookworm main' "$(<"$source_file")"
  [[ "$(<"$source_file.linux-setup.bak")" == "$original" ]] || fail "mirror command did not preserve the original source backup on success"
  [[ "$(<"$apt_state")" == "1" ]] || fail "mirror command did not validate the successful source change"
  assert_contains 'Successfully switched APT mirror to deb.debian.org.' "$output"
}

test_apt_mirror_partial_apply_rollback() {
  local apt_root os_release fake_bin source_file extra_file original_source original_extra output status apt_state real_cp
  apt_root="$TMP_DIR/apt-partial"
  os_release="$TMP_DIR/os-release-partial"
  fake_bin="$TMP_DIR/fake-bin-partial"
  source_file="$apt_root/sources.list"
  extra_file="$apt_root/sources.list.d/debian.sources"
  apt_state="$TMP_DIR/apt-partial-count"
  real_cp="$(command -v cp)"
  mkdir -p "$apt_root/sources.list.d"
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$os_release"
  printf 'deb https://mirror.old/debian bookworm main\n' > "$source_file"
  printf 'URIs: https://mirror.old/debian\n' > "$extra_file"
  original_source="$(<"$source_file")"
  original_extra="$(<"$extra_file")"
  write_mirror_fakes "$fake_bin"
  cat > "$fake_bin/cp" <<EOF
#!/usr/bin/env bash
last="\${!#}"
if [[ "\$*" == *".candidate"* && "\$last" == "\$FAIL_COPY_TARGET" ]]; then
  exit 1
fi
exec "$real_cp" "\$@"
EOF
  chmod 755 "$fake_bin/cp"

  set +e
  output="$(PATH="$fake_bin:$PATH" FAKE_APT_STATE="$apt_state" FAIL_COPY_TARGET="$extra_file" LINUX_SETUP_APT_ETC_DIR="$apt_root" LINUX_SETUP_OS_RELEASE_FILE="$os_release" bash "$ROOT_DIR/commands/maintain/mirror.sh" --apply 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "mirror command succeeded after a partial source replacement failure"
  [[ "$(<"$source_file")" == "$original_source" ]] || fail "mirror command did not restore the first source after a partial replacement failure"
  [[ "$(<"$extra_file")" == "$original_extra" ]] || fail "mirror command did not restore the second source after a partial replacement failure"
  [[ ! -e "$apt_state" ]] || fail "mirror command ran apt-get after source replacement failed"
  assert_contains 'original source files were restored' "$output"
}

test_btrfs_capacity_math() {
  local task_path install_line capacity_line
  source "$ROOT_DIR/lib/btrfs.sh"
  [[ "$(btrfs_layout_required_kib flat-root-to-rootfs-home 3072)" == "6144" ]] || fail "flat-root capacity calculation is wrong"
  [[ "$(btrfs_layout_required_kib split-home-from-existing-rootfs 3072)" == "3072" ]] || fail "split-home capacity calculation is wrong"
  btrfs_layout_has_capacity 6144 6144 || fail "equal capacity should pass"
  if btrfs_layout_has_capacity 6143 6144; then
    fail "insufficient capacity passed"
  fi
  if btrfs_layout_required_kib unsupported 1 >/dev/null; then
    fail "unsupported layout mode produced a capacity requirement"
  fi

  task_path="$ROOT_DIR/tasks/system/prepare-btrfs-layout.sh"
  install_line="$(grep -n 'install_packages btrfs-progs rsync' "$task_path" | cut -d: -f1)"
  capacity_line="$(grep -n 'require_layout_capacity' "$task_path" | tail -n 1 | cut -d: -f1)"
  (( capacity_line > install_line )) || fail "Btrfs capacity check runs before dependency installation"
}

test_common_import() {
  (
    source "$ROOT_DIR/lib/common.sh"
    local function_name
    for function_name in \
      run_as_root \
      record_result \
      component_set \
      install_packages \
      preflight_reset \
      github_release_parse_latest \
      detect_managed_shell_env \
      current_root_device \
      rebuild_grub_if_possible; do
      declare -F "$function_name" >/dev/null || fail "common import omitted: $function_name"
    done
  )
}

test_component_catalog() {
  (
    source "$ROOT_DIR/lib/common.sh"
    local_component=''
    for local_component in "${SETUP_COMPONENTS[@]}" "${UPDATE_COMPONENTS[@]}"; do
      component_variable "$local_component" >/dev/null || fail "component has no variable: $local_component"
      [[ -n "${COMPONENT_DESCRIPTION[$local_component]:-}" ]] || fail "component has no description: $local_component"
    done
    for local_component in "${MANAGED_APP_COMPONENTS[@]}"; do
      [[ -f "$ROOT_DIR/tasks/apps/external/$local_component.sh" ]] \
        || fail "managed app has no matching adapter: $local_component"
    done

    component_reset "${UPDATE_COMPONENTS[@]}"
    component_any_selected "${UPDATE_COMPONENTS[@]}" && fail "component reset left a selected update"
    component_set miniforge 1
    [[ "$INSTALL_MINIFORGE" == 1 ]] || fail "component selection did not reach its workflow variable"
    component_any_selected "${UPDATE_COMPONENTS[@]}" || fail "selected component was not detected"
  )
}

test_repository_layout() {
  [[ ! -d "$ROOT_DIR/flows" ]] || fail "legacy flows directory still exists"
  ! grep -q '/tasks/' "$ROOT_DIR/manage.sh" || fail "public dispatcher contains task implementation paths"

  local path
  for path in \
    commands/setup/stage1.sh \
    commands/setup/stage2.sh \
    commands/update/all.sh \
    commands/update/packages.sh \
    commands/update/apps.sh \
    commands/maintain/repair.sh \
    commands/maintain/mirror.sh \
    commands/snapshot/create.sh \
    commands/snapshot/rollback.sh \
    commands/shell/sync.sh \
    commands/check.sh \
    commands/menu.sh; do
    [[ -x "$ROOT_DIR/$path" ]] || fail "public command handler is missing or not executable: $path"
  done
}

test_stage1_requires_manual_reboot() {
  local preview
  preview="$(bash "$ROOT_DIR/manage.sh" setup stage1 --check)"
  assert_contains 'reboot manually' "$preview"
  assert_not_contains '--reboot' "$preview"
}

test_interactive_menu_quit() {
  command -v script >/dev/null 2>&1 || return 0
  local output
  output="$(printf '7\n' | script -qec "env LINUX_SETUP_FORCE_TEXT_UI=1 bash '$ROOT_DIR/manage.sh'" /dev/null)"
  assert_contains 'Linux Manager actions' "$output"
}

test_public_checks() {
  local args script
  for script in $(find "$ROOT_DIR" -name '*.sh' -not -path "$ROOT_DIR/.git/*" | sort); do
    bash -n "$script"
  done

  for args in \
    'setup stage1 --help' \
    'setup stage2 --help' \
    'update --help' \
    'update packages --help' \
    'update apps --help' \
    'maintain repair --help' \
    'maintain mirror --help' \
    'snapshot create --help' \
    'snapshot rollback --help' \
    'shell sync --help' \
    'driver nvidia --help'; do
    # Each literal is an argument vector for the stable public CLI.
    bash "$ROOT_DIR/manage.sh" $args >/dev/null
  done

  bash "$ROOT_DIR/manage.sh" update apps --check >/dev/null
  bash "$ROOT_DIR/tasks/apps/install-external-apps.sh" --check >/dev/null
  bash "$ROOT_DIR/tasks/system/remove-snap.sh" --check >/dev/null
}

main() {
  python3 "$ROOT_DIR/tests/docs.py"
  test_result_protocol
  test_apt_mirror_transform
  test_apt_mirror_rollback
  test_apt_mirror_success
  test_apt_mirror_partial_apply_rollback
  test_btrfs_capacity_math
  test_common_import
  test_component_catalog
  test_repository_layout
  test_stage1_requires_manual_reboot
  test_interactive_menu_quit
  test_public_checks
  printf 'tests: pass\n'
}

main "$@"
