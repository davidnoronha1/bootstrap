"""Bootstrap startup/transfer regressions; no package installs or network access.

Run with: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap.sh"
STEPS = "user network docker nvidia ghostty tools neovim toolchains vscode configs extras scpt rec".split()


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bootstrap-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.script = self.repo / "bootstrap.sh"
        self.script.write_text(SCRIPT.read_text())
        self.library = self.repo / "library.sh"
        self.library.write_text(SCRIPT.read_text().rsplit('main "$@"', 1)[0])
        self.home = self.root / "home"
        self.home.mkdir()
        self.files = self.repo / "files"
        self.files.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), NO_COLOR="1",
                        CODEX_HOME=str(self.home / ".codex"),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        BOOTSTRAP_FILES_DIR=str(self.files))

    def bash(self, body, *args, env=None):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift\n' + body,
             "bootstrap-test", str(self.library), *args],
            cwd=self.repo, env=env or self.env, text=True, capture_output=True,
        )

    def assert_ok(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_cli_errors_before_color_initialization(self):
        for args, expected in [(["--unknown"], "unknown option"),
                               ([""], "unknown option"),
                               (["--user"], "requires a value"),
                               (["--files-dir"], "requires a value"),
                               (["--files-dir", "--remote"], "requires a value")]:
            with self.subTest(args=args):
                proc = subprocess.run(["bash", str(self.script), *args], env=self.env,
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode, 1)
                self.assertIn(expected, proc.stderr)
                self.assertNotIn("unbound variable", proc.stderr)

    def test_help(self):
        self.assert_ok(self.bash('main --help'))

    def test_temp_files_from_subshells_are_cleaned_even_with_custom_tmpdir(self):
        proc = self.bash('''
            init_tmp || exit 1
            root="$TEMP_ROOT"
            a="$(new_tmp)"; b="$(new_tmpdir)"
            (new_tmp > "$b/child-path")
            test -f "$a" && test -f "$(cat "$b/child-path")" || exit 1
            [[ "$root" == /tmp/bootstrap.* ]] || exit 1
            cleanup_tmp
            test ! -e "$root"
        ''', env=dict(self.env, TMPDIR=str(self.root / "does-not-exist")))
        self.assert_ok(proc)

    def test_custom_files_directory_does_not_hide_bundled_tools(self):
        custom = self.root / "custom settings"
        custom.mkdir()
        proc = self.bash('''
            step_preflight() { test "$SCRIPT_DIR" = "$PWD"; }
            ensure_home_ownership() { :; }
            main --remote --yes --files-dir "$1" ''' + " ".join(
                "--skip-" + step for step in
                "user network docker nvidia ghostty tools nvim toolchains vscode configs extras scpt rec".split()), str(custom))
        self.assert_ok(proc)

    def test_failed_step_returns_failure_from_main(self):
        stubs = "\n".join(f"step_{name}() {{ :; }}" for name in STEPS)
        proc = self.bash(stubs + '''
            step_preflight() { :; }
            step_tools() { return 1; }
            ensure_home_ownership() { :; }
            main --remote --yes
        ''')
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("1 failed step", proc.stdout)

    def offline_run(self, answer):
        stubs = "\n".join(f"step_{name}() {{ echo RAN:{name}; }}" for name in STEPS)
        return self.bash(stubs + '''
            getent() { [[ "$1" != ahosts ]] && command getent "$@"; }
            start_sudo_keepalive() { :; }
            gpu_status() { :; }
            ensure_home_ownership() { :; }
            confirm() { case "$1" in Continue*) [[ ''' + answer + ''' == y ]] ;; *) return 0 ;; esac; }
            main --remote
        ''')

    def test_offline_skips_download_steps_without_running_them(self):
        proc = self.offline_run('y')
        self.assert_ok(proc)
        self.assertIn('DNS lookups are failing', proc.stderr)
        ran = {l.split(':', 1)[1] for l in proc.stdout.splitlines() if l.startswith('RAN:')}
        self.assertEqual(ran, {'user', 'network', 'configs', 'scpt'})
        self.assertIn('skipped: offline', proc.stdout)
        self.assertNotIn('command not found', proc.stderr)

    def test_offline_declined_aborts_in_preflight(self):
        proc = self.offline_run('n')
        self.assertEqual(proc.returncode, 1)
        self.assertIn('preflight failed', proc.stderr)
        self.assertNotIn('RAN:', proc.stdout)

    def test_fetch_key_failure_never_reaches_gpg(self):
        proc = self.bash('''
            init_tmp || exit 1
            trap cleanup_tmp EXIT
            curl() { return 6; }
            asroot() { echo GPG-CALLED; }
            fetch_key https://example.invalid/key "$PWD/k.gpg"
        ''')
        self.assertEqual(proc.returncode, 1)
        self.assertIn('could not download signing key', proc.stderr)
        self.assertNotIn('GPG-CALLED', proc.stdout)

    def test_write_failure_does_not_report_success(self):
        proc = self.bash('''
            init_tmp || exit 1
            trap cleanup_tmp EXIT
            TARGET_USER="$(id -un)"
            asroot() { return 1; }
            content() { printf 'settings'; }
            _write_file "$HOME/new-config" content
        ''')
        self.assertEqual(proc.returncode, 1)
        self.assertNotIn("wrote ", proc.stdout)

    def test_ai_configs_copy_privately_and_preserve_existing_by_default(self):
        for app, name, data in [("codex", "config.toml", 'model = "test"\n'),
                                ("codex", "AGENTS.md", "custom instructions\n"),
                                ("opencode", "opencode.jsonc", "{}\n")]:
            (self.files / app).mkdir(exist_ok=True)
            (self.files / app / name).write_text(data)
        target = self.home / "target"
        target.mkdir()
        opencode = target / ".config/opencode/opencode.jsonc"
        opencode.parent.mkdir(parents=True)
        opencode.write_text("existing")
        proc = self.bash('''
            init_tmp || exit 1
            trap cleanup_tmp EXIT
            FILES_DIR="$PWD/files"
            TARGET_USER="$(id -un)"
            asroot() { command "$@"; }
            confirm() { [[ "$2" == y ]]; }
            _install_ai_configs "$HOME/target"
        ''')
        self.assert_ok(proc)
        codex = target / ".codex/config.toml"
        self.assertEqual(codex.read_text(), 'model = "test"\n')
        self.assertEqual(codex.stat().st_mode & 0o777, 0o600)
        self.assertEqual(opencode.read_text(), "existing")

    def test_claude_settings_helper_does_not_depend_on_callers_home_variable(self):
        (self.files / "claude").mkdir()
        (self.files / "claude/settings.json").write_text('{}\n')
        proc = self.bash('''
            init_tmp || exit 1
            trap cleanup_tmp EXIT
            FILES_DIR="$PWD/files"
            TARGET_USER="$(id -un)"
            asroot() { command "$@"; }
            unset home
            _merge_claude_settings "$HOME/target"
        ''')
        self.assert_ok(proc)
        self.assertEqual((self.home / "target/.claude/settings.json").read_text(), '{}\n')

    def setup_ssh_mock(self, mode="success"):
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        log = self.root / "ssh.jsonl"
        mock = mock_bin / "ssh"
        mock.write_text(textwrap.dedent('''\
            #!/usr/bin/env python3
            import json, os, pathlib, shlex, subprocess, sys
            args = sys.argv[1:]
            mode = os.environ['TEST_MODE']
            with open(os.environ['SSH_LOG'], 'a') as f:
                f.write(json.dumps(args) + '\\n')
            if 'ControlMaster=yes' in args:
                sys.exit(19 if mode == 'auth_failure' else 0)
            if '-O' in args:
                sys.exit(0)
            cmd = args[-1]
            if cmd.startswith('for c in') and mode == 'missing_bash':
                print('bash ', end=''); sys.exit(0)
            if cmd.startswith('mktemp ') and mode == 'bad_path':
                print('/home/unexpected'); sys.exit(0)
            if cmd.startswith('cat >') and mode == 'transfer_failure':
                sys.stdin.buffer.read(); sys.exit(23)
            if cmd.startswith('cd '):
                words = shlex.split(cmd)
                stage = pathlib.Path(words[1])
                argv = words[5:]
                with open(os.environ['RUN_ARGS'], 'w') as f:
                    json.dump(argv, f)
                with open(os.environ['STAGED_FILES'], 'w') as f:
                    json.dump({str(p.relative_to(stage/'files')): p.read_text()
                               for p in (stage/'files').rglob('*') if p.is_file()}, f)
                source = (stage / 'bootstrap.sh').read_text().rsplit('main "$@"', 1)[0]
                steps = 'user network docker nvidia ghostty tools neovim toolchains vscode configs extras scpt rec'.split()
                source += '\\nstep_preflight() { :; }\\nensure_home_ownership() { :; }\\n'
                source += '\\n'.join('step_' + step + '() { :; }' for step in steps)
                source += '\\nmain "$@"\\n'
                runner = stage / 'smoke.sh'
                runner.write_text(source)
                if mode == 'run_failure': sys.exit(42)
                sys.exit(subprocess.run(['bash', str(runner), *argv], cwd=stage).returncode)
            sys.exit(subprocess.run(['bash', '-c', cmd]).returncode)
        '''))
        mock.chmod(0o755)
        env = dict(self.env, PATH=str(mock_bin) + ':' + self.env['PATH'],
                   SSH_LOG=str(log), TEST_MODE=mode,
                   RUN_ARGS=str(self.root/'run-args.json'),
                   STAGED_FILES=str(self.root/'staged-files.json'))
        return env, log

    def remote(self, original_args, mode="success", files=None, setup=""):
        env, log = self.setup_ssh_mock(mode)
        args = " ".join(shlex.quote(a) for a in original_args)
        proc = self.bash('''
            init_tmp || exit 1
            trap cleanup_tmp EXIT
            SCRIPT_DIR="$PWD"
            FILES_DIR=''' + shlex.quote(str(files or self.files)) + '''
            read_line() { REPLY='-p 2222 user@example'; }
            confirm() { return 0; }
            ORIGINAL_ARGS=(''' + args + ''')
            ''' + setup + '''
            remote_bootstrap
        ''', env=env)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        socket = calls[0][1].split('=', 1)[1]
        self.assertTrue(socket.startswith('/tmp/bootstrap-ssh.'))
        self.assertFalse(Path(socket).parent.exists())
        self.assertEqual(sum('ControlMaster=yes' in c for c in calls), 1)
        for call in calls:
            self.assertNotIn('-M', call)
        for call in calls[1:]:
            self.assertIn('BatchMode=yes', call)
            self.assertIn('ControlPath=' + socket, call)
        if mode != 'auth_failure':
            self.assertTrue(any('-O' in c for c in calls))
        for call in calls:
            if call[-1].startswith('cd '):
                self.assertIn('-t', call)
                self.assertFalse(Path(shlex.split(call[-1])[1]).exists())
        return proc, calls

    def test_remote_without_flags_runs_startup(self):
        proc, _ = self.remote([])
        self.assert_ok(proc)
        argv = json.loads((self.root / 'run-args.json').read_text())
        self.assertNotIn('', argv)
        self.assertEqual(argv[0], '--remote')
        self.assertIn('Bootstrap complete', proc.stdout)

    def test_remote_custom_files_and_live_ai_settings(self):
        custom = self.root / "custom configs"
        custom.mkdir()
        (custom / 'tmux.conf').write_text('tmux fixture')
        codex = self.home / '.codex'
        codex.mkdir()
        (codex / 'config.toml').write_text('model = "fixture"')
        (codex / 'auth.json').write_text('must not transfer')
        (codex / 'history.jsonl').write_text('must not transfer')
        opencode = self.home / '.config/opencode'
        opencode.mkdir(parents=True)
        (opencode / 'opencode.jsonc').write_text('{"theme":"fixture"}')
        (opencode / 'auth.json').write_text('must not transfer')
        proc, _ = self.remote(['--files-dir', str(custom), '--skip-docker'], files=custom)
        self.assert_ok(proc)
        staged = json.loads((self.root / 'staged-files.json').read_text())
        self.assertEqual(staged, {'tmux.conf': 'tmux fixture',
                                 'codex/config.toml': 'model = "fixture"',
                                 'opencode/opencode.jsonc': '{"theme":"fixture"}'})
        argv = json.loads((self.root / 'run-args.json').read_text())
        self.assertIn('--skip-docker', argv)
        self.assertNotIn(str(custom), argv)
        self.assertTrue(argv[argv.index('--files-dir')+1].startswith('/tmp/bootstrap-remote.'))

    def test_remote_copies_script_under_a_different_name(self):
        renamed = self.repo / 'setup.sh'
        self.script.rename(renamed)
        proc, _ = self.remote([], setup='SCRIPT_FILE=' + shlex.quote(str(renamed)))
        self.assert_ok(proc)
        self.assertIn('Bootstrap complete', proc.stdout)

    def test_host_name_falls_back_without_hostname_binary(self):
        proc = self.bash('hostname() { return 127; }; host_name',
                         env=dict(self.env))
        self.assert_ok(proc)
        self.assertEqual(proc.stdout.strip(), os.uname().nodename)

    def test_remote_stages_ai_settings_without_prompting(self):
        codex = self.home / '.codex'
        codex.mkdir()
        (codex / 'config.toml').write_text('model = "fixture"')
        prompts = self.root / 'prompts.txt'
        proc, _ = self.remote([], setup='confirm() { printf "%s\\n" "$1" >> '
                              + shlex.quote(str(prompts)) + '; }')
        self.assert_ok(proc)
        self.assertNotIn('codex', prompts.read_text())
        staged = json.loads((self.root / 'staged-files.json').read_text())
        self.assertEqual(staged['codex/config.toml'], 'model = "fixture"')

    def test_remote_manage_flags_are_parsed(self):
        proc, _ = self.remote(['manage', 'list'])
        self.assert_ok(proc)
        self.assertIn('no managed tools recorded', proc.stdout)

    def test_remote_failure_paths_clean_up(self):
        for mode, expected in [('auth_failure', 1), ('transfer_failure', 1),
                               ('run_failure', 42), ('bad_path', 1),
                               ('missing_bash', 1)]:
            with self.subTest(mode=mode):
                # Each mock has separate log/bin paths.
                case = BootstrapTests('test_help')
                case.setUp()
                try:
                    proc, calls = case.remote([], mode)
                    self.assertEqual(proc.returncode, expected, proc.stdout + proc.stderr)
                    if mode == 'missing_bash':
                        self.assertIn('missing: bash', proc.stderr)
                    if mode in ('transfer_failure', 'run_failure', 'missing_bash'):
                        self.assertTrue(any(c[-1].startswith('rm -rf --') for c in calls))
                finally:
                    case.doCleanups()


if __name__ == '__main__':
    unittest.main()
