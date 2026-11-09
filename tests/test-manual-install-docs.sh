#!/usr/bin/env bash
# TC manual documentation contract: standalone Compose CONFIG only, never an engine.
# Bash 3.2/5; POSIX tools + Python 3. All credentials below are inert test placeholders.
set -euo pipefail
ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
RUNS="$ROOT/.work/manual-tc-contract/runs"
mkdir -p "$RUNS"
LOGDIR="$RUNS/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir "$LOGDIR"                         # never reuse/truncate an earlier run
set -C
# File-descriptor duplication also works where sandbox policy blocks /dev/fd
# process substitution. Replay both complete logs at exit, with the result last.
exec 3>&1 4>&2
exec > "$LOGDIR/stdout.log" 2> "$LOGDIR/stderr.log"
T=''
finish() {
  rc=$?
  trap - EXIT
  if [ -n "$T" ]; then rm -rf "$T"; fi
  if [ "$rc" -eq 0 ]; then
    printf 'PASS: manual TC contract; logs: %s\n' "$LOGDIR"
  else
    printf 'FAIL: manual TC contract (exit %s); logs: %s\n' "$rc" "$LOGDIR"
  fi
  exec 1>&3 2>&4
  cat "$LOGDIR/stderr.log" >&2
  cat "$LOGDIR/stdout.log"
  exit "$rc"
}
trap finish EXIT
if [ -z "${HOST_COMPOSE:-}" ] || [ ! -f "$HOST_COMPOSE" ] || [ ! -x "$HOST_COMPOSE" ]; then
  echo 'HOST_COMPOSE must name an executable standalone Compose client' >&2
  exit 1
fi
HOST_COMPOSE="$(cd -P "$(dirname "$HOST_COMPOSE")" && pwd -P)/$(basename "$HOST_COMPOSE")"
DOC="${1:-$ROOT/README.docker.md}"
[ "$#" -le 1 ] && [ -f "$DOC" ] || { echo 'Usage: HOST_COMPOSE=path bash test-manual-install-docs.sh [README]' >&2; exit 1; }
TB="${TMPDIR:-/tmp}"
TB="$(cd -P "$TB" && pwd -P)"
T="$(mktemp -d "${TB%/}/tc-manual-contract.XXXXXX")"
T="$(cd -P "$T" && pwd -P)"
python3 -I - "$ROOT" "$DOC" "$LOGDIR" "$T" "$HOST_COMPOSE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import traceback

ROOT, DOC, LOG, TEMP, HOST = [Path(v).resolve() for v in sys.argv[1:]]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# Inherit no caller Compose interpolation/CLI options. No Docker command except config.
ENV = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'SYSTEMROOT') if k in os.environ}
ENV['HOST_COMPOSE'] = str(HOST)


def command(argv, cwd, stdout=None, env=None):
    print('command:', shlex.join([str(x) for x in argv]), flush=True)
    result = subprocess.run([str(x) for x in argv], cwd=str(cwd), env=env or ENV,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if stdout:
        Path(stdout).write_bytes(result.stdout)
    else:
        sys.stdout.write(result.stdout.decode(errors='replace'))
    sys.stderr.write(result.stderr.decode(errors='replace'))
    print('exit:', result.returncode, flush=True)
    return result


def blocks(text):
    """Read fenced blocks and numbered sections; never mistake prose for executable code."""
    section = ''
    fence = None
    lines = []
    for line in text.splitlines():
        if fence is None:
            heading = re.match(r'^#{2,4} (\d+(?:\.\d+)*)[. ]', line)
            if heading:
                section = heading.group(1)
            opening = re.match(r'^\s*```(\w*)\s*$', line)
            if opening:
                fence = opening.group(1)
                lines = []
        elif re.match(r'^\s*```\s*$', line):
            yield section, fence, '\n'.join(lines) + '\n'
            fence = None
        else:
            lines.append(line)
    require(fence is None, 'unterminated document fence')


def prefix_of(text):
    matches = [body for _, lang, body in blocks(text)
               if lang == 'bash' and body.splitlines()[0:1] == ['# manual-prefix']]
    require(len(matches) == 1, 'expected exactly one # manual-prefix bash fence')
    prefix = matches[0]
    for name in ('INSTALL_ROOT', 'TC_PROJECT'):
        require(len(re.findall(r'^' + name + r'=.*$', prefix, re.M)) == 1,
                'expected exactly one assignment: ' + name)
    return prefix


GUARDS = ('test -f secrets/secrets.env', 'test -s secrets/secrets.env',
          'test ! -L secrets/secrets.env', 'test -f user.env',
          'test -f customer.override.yml')


def static_rules(text):
    prefix = prefix_of(text)
    require('--env-file .env -f compose.docker.yml' not in text, 'old manual prefix')
    section = ''
    prefix_lines = prefix.splitlines()
    in_prefix = False
    for line in text.splitlines():
        heading = re.match(r'^#{2,4} (\d+(?:\.\d+)*)[. ]', line)
        if heading:
            section = heading.group(1)
        if line == '# manual-prefix':
            in_prefix = True
        if in_prefix and line.strip() == '```':
            in_prefix = False
        if 'TC_INIT' in line:
            # 4.1 must define the bootstrap array; executable uses belong only below.
            definition = in_prefix and re.match(r'^TC_INIT=\(', line)
            require(definition or section in ('4.5', '4.6', '5.3'),
                    'TC_INIT outside bootstrap/certificate sections: ' + section)
        if section.split('.')[0] in ('6', '7'):
            require(not re.search(r'4\.[56]', line), 'update/restore refers to bootstrap section')
    regen = []
    for section, lang, body in blocks(text):
        if lang != 'bash':
            continue
        if re.search(r'\b(?:run|up|rm|build)\b[^\n]*\binit-secrets\b', body):
            require(section in ('4.5', '4.6', '5.3'),
                    'init-secrets execution outside allowed sections: ' + section)
        if section == '5.3' and '"${TC_INIT[@]}"' in body:
            regen.append(body)
    require(len(regen) == 1, 'expected one certificate regeneration command block')
    regen = regen[0]
    init_at = regen.index('"${TC_INIT[@]}"')
    for guard in GUARDS:
        require(guard + ' &&' in regen[:init_at], 'missing fail-closed guard: ' + guard)
    # Every step before init must remain in the same && chain (no ignored test result).
    for line in regen[:init_at].splitlines():
        require(not line.strip() or line.rstrip().endswith('&&'), 'broken fail-closed && chain')
    backup = [body for section, lang, body in blocks(text)
              if section == '7.2' and lang == 'bash' and 'tar -czf' in body]
    require(len(backup) == 1, 'expected one backup tar command')
    tarline = next(line for line in backup[0].splitlines() if 'tar -czf' in line)
    args = shlex.split(tarline)
    require('user.env' in args and 'customer.override.yml' in args, 'customer backup files missing')
    # Section 6 edits image tags of the installed compose.docker.yml in place, so it must be backed up.
    require('compose.docker.yml' in args, 'installed compose.docker.yml missing from backup')
    require('.env' not in args, 'obsolete .env backup input')
    return prefix, regen


# Compose's canonical YAML is an indentation-only subset. This fallback does not need
# PyYAML/jq; unsupported syntax fails closed. JSON is preferred and saved verbatim.
def canonical_yaml(text):
    def scalar(value):
        if value.startswith('"'):
            return json.loads(value)
        if value.startswith("'") and value.endswith("'"):
            return value[1:-1].replace("''", "'")
        if value in ('{}', '[]'):
            return json.loads(value)
        if value in ('true', 'false', 'null'):
            return json.loads(value)
        require(value not in ('|', '>') and not value.startswith(('&', '*', '!')),
                'unsupported canonical YAML scalar')
        return value

    rows = [(len(line) - len(line.lstrip()), line.strip()) for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]

    def pair(value):
        match = re.match(r'^([A-Za-z0-9_.-]+):(?:\s+(.*)|$)', value)
        require(match is not None, 'unsupported canonical YAML mapping: ' + value)
        return match.group(1), match.group(2) or ''

    def parse(index, indent):
        is_list = rows[index][1].startswith('- ')
        out = [] if is_list else {}
        while index < len(rows) and rows[index][0] == indent:
            value = rows[index][1]
            if is_list:
                require(value.startswith('- '), 'mixed YAML collection')
                value = value[2:]
                if re.match(r'^[A-Za-z0-9_.-]+:(?:\s|$)', value):
                    key, tail = pair(value)
                    item = {key: scalar(tail) if tail else None}
                    index += 1
                    if index < len(rows) and rows[index][0] > indent:
                        more, index = parse(index, rows[index][0])
                        require(isinstance(more, dict), 'unsupported YAML sequence mapping')
                        item.update(more)
                    out.append(item)
                else:
                    out.append(scalar(value))
                    index += 1
            else:
                key, tail = pair(value)
                index += 1
                if tail:
                    out[key] = scalar(tail)
                elif index < len(rows) and rows[index][0] > indent:
                    out[key], index = parse(index, rows[index][0])
                else:
                    out[key] = None
        return out, index
    require(rows, 'empty YAML render')
    result, end = parse(0, rows[0][0])
    require(end == len(rows), 'unconsumed canonical YAML')
    return result


# Copy tracked *working tree bytes*, never git archive/HEAD or prior fixtures.
listing = command(['git', '-C', ROOT, 'ls-files', '-z'], ROOT, LOG / 'tracked-files.nul')
require(listing.returncode == 0, 'git ls-files failed')
tracked = [os.fsdecode(x) for x in listing.stdout.split(b'\0') if x]
tracked = [x for x in tracked if x != '.work' and not x.startswith('.work/')]
manifest = {}
for relative in tracked:
    source = ROOT / relative
    require(source.is_file() or source.is_symlink(), 'tracked source missing: ' + relative)
    manifest[relative] = (os.readlink(source) if source.is_symlink()
                          else hashlib.sha256(source.read_bytes()).hexdigest())
(LOG / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def copy_source(target):
    target.mkdir()
    for relative in tracked:
        source, dest = ROOT / relative, target / relative
        dest.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        if source.is_symlink():
            dest.symlink_to(os.readlink(source))
        else:
            shutil.copyfile(source, dest)
            dest.chmod(source.stat().st_mode & 0o777)
    return target


def unchanged_vendor(target):
    for relative, digest in manifest.items():
        dest = target / relative
        actual = os.readlink(dest) if dest.is_symlink() else hashlib.sha256(dest.read_bytes()).hexdigest()
        require(actual == digest, 'vendor file changed after copy: ' + relative)


def inputs(target, letter, override):
    number = 1 if letter == 'a' else 2
    http, https = 18080 + number, 18443 + number
    scheme, ws = ('https', 'wss') if letter == 'a' else ('http', 'ws')
    port = https if letter == 'a' else http
    values = {'TC_DB_NAME': 'contract_tc_' + letter, 'AUTH_DB_NAME': 'contract_auth_' + letter,
              'GITEA_DB_NAME': 'contract_git_' + letter, 'TC_HTTP_PORT': str(http),
              'TC_HTTPS_PORT': str(https), 'EXTERNAL_URL': '%s://tc-%s.example.test:%s' % (scheme, letter, port),
              'BROKER_WS_URL': '%s://tc-%s.example.test:%s/mqtt' % (ws, letter, port),
              'PUBLIC_BROKER_WS_URL': '%s://tc-%s.example.test:%s/mqtt' % (ws, letter, port)}
    # Replace example placeholders only; preserve all other example assignments/comments.
    example = (target / '.env.example').read_text()
    for old, new in {'your_service_admin_password': 'dummy_admin', 'your_db_root_password': 'dummy_root',
                     'your_db_password': 'dummy_db', 'your-domain.com': 'tc.example.test',
                     'your-public-domain.com': 'public.example.test'}.items():
        example = example.replace(old, new)
    for key, value in values.items():
        pattern = r'^' + key + '=.*$'
        if re.search(pattern, example, re.M):
            example = re.sub(pattern, key + '=' + value, example, flags=re.M)
        else:
            example += '\n' + key + '=' + value + '\n'
    envfile = target / 'user.env'
    envfile.write_text(example)
    envfile.chmod(0o600)
    (target / 'customer.override.yml').write_text(override)
    require(envfile.stat().st_mode & 0o777 == 0o600, 'user.env not 0600')
    return values


def render(args, folder, stem):
    result = command(args + ['config', '--format', 'json'], TEMP, folder / (stem + '.json'))
    if result.returncode == 0:
        return json.loads(result.stdout)
    require(b'unknown' in result.stderr.lower() and b'format' in result.stderr.lower(),
            'Compose config failed (not an unsupported JSON format)')
    result = command(args + ['config'], TEMP, folder / (stem + '.yaml'))
    require(result.returncode == 0, 'Compose YAML fallback failed')
    parsed = canonical_yaml(result.stdout.decode())
    (folder / (stem + '.parsed.json')).write_text(json.dumps(parsed, indent=2) + '\n')
    return parsed


def fail_closed(regen, folder):
    # Execute the actual 5.3 block on absent/empty/symlink/non-regular secret input
    # and absent customer inputs. No valid init is ever run; all files are inert sentinels.
    for broken in ('missing', 'empty', 'symlink', 'directory', 'user.env', 'customer.override.yml'):
        root = folder / ('guard-' + broken)
        (root / 'secrets').mkdir(parents=True)
        (root / 'user.env').touch()
        (root / 'customer.override.yml').touch()
        secret = root / 'secrets/secrets.env'
        if broken == 'directory':
            secret.mkdir()
        elif broken == 'symlink':
            (root / 'dummy-input').write_text('inert contract sentinel\n')
            secret.symlink_to(root / 'dummy-input')
        elif broken != 'missing':
            secret.write_text('' if broken == 'empty' else 'inert contract sentinel\n')
        if broken in ('user.env', 'customer.override.yml'):
            (root / broken).unlink()
        # All side effects are stubbed: a broken guard must fail before any of them.
        setup = '''docker(){ echo UNEXPECTED_SIDE_EFFECT; return 0; }
mkdir(){ echo UNEXPECTED_SIDE_EFFECT; return 0; }
mv(){ echo UNEXPECTED_SIDE_EFFECT; return 0; }
TC_INIT=(docker compose)
TC=(docker compose)
'''
        script = folder / ('guard-' + broken + '.bash')
        script.write_text(setup + 'INSTALL_ROOT=' + shlex.quote(str(root)) + '\n' + regen)
        result = command(['bash', script], TEMP, folder / ('guard-' + broken + '.stdout'))
        require(result.returncode != 0 and b'UNEXPECTED_SIDE_EFFECT' not in result.stdout,
                'certificate regeneration did not fail closed: ' + broken)


def check_document(document, label):
    folder = LOG / label
    folder.mkdir()
    text = document.read_text()
    (folder / 'README.input.md').write_text(text)
    prefix, regen = static_rules(text)
    fail_closed(regen, folder)
    # A minimal A override and the exact public-HTTP YAML fence from section 4.3.
    http_overrides = [body for section, lang, body in blocks(text)
                      if section == '4.3' and lang == 'yaml' and 'nginx.http.conf' in body]
    require(len(http_overrides) == 1, 'expected one HTTP customer override in 4.3')
    configurations = []
    for letter in ('a', 'b'):
        install = copy_source(TEMP / (label + '-install-' + letter))
        values = inputs(install, letter, 'services: {}\n' if letter == 'a' else http_overrides[0])
        project = 'manual-contract-' + label + '-' + letter
        # These are the ONLY changes to the extracted prefix.
        executable = re.sub(r'^INSTALL_ROOT=.*$', 'INSTALL_ROOT=' + shlex.quote(str(install)), prefix, flags=re.M)
        executable = re.sub(r'^TC_PROJECT=.*$', 'TC_PROJECT=' + shlex.quote(project), executable, flags=re.M)
        # Arrays remain in the same Bash subshell; save NUL-delimited arguments for
        # inspection and repeated CONFIG renders, without eval or rebuilding a prefix.
        script = folder / (letter + '.bash')
        script.write_text('''set -euo pipefail
docker(){ [ "$1" = compose ] || return 97; shift; "$HOST_COMPOSE" "$@"; }
''' + executable + '\nprintf "%s\\0" "${TC[@]}" > "$ARGS_MAIN"\n'
                          + 'printf "%s\\0" "${TC_INIT[@]}" > "$ARGS_INIT"\n'
                          + '''if ! "${TC[@]}" config --format json > "$RENDER_MAIN"; then
  "${TC[@]}" config > "$RENDER_MAIN_YAML"
fi
if ! "${TC_INIT[@]}" config --format json > "$RENDER_INIT"; then
  "${TC_INIT[@]}" config > "$RENDER_INIT_YAML"
fi
''')
        env = dict(ENV)
        for name, suffix in (('ARGS_MAIN', '.main.args'), ('ARGS_INIT', '.init.args'),
                             ('RENDER_MAIN', '.main.json'), ('RENDER_INIT', '.init.json'),
                             ('RENDER_MAIN_YAML', '.main.yaml'), ('RENDER_INIT_YAML', '.init.yaml')):
            env[name] = str(folder / (letter + suffix))
        result = command(['bash', script], TEMP, folder / (letter + '.prefix.stdout'), env)
        require(result.returncode == 0, 'extracted prefix/config failed for ' + letter)
        arrays = []
        for kind in ('main', 'init'):
            args = (folder / (letter + '.' + kind + '.args')).read_bytes().split(b'\0')[:-1]
            args = [os.fsdecode(arg) for arg in args]
            require(args[:2] == ['docker', 'compose'], 'prefix must invoke docker compose')
            for flag, expected in (('--project-name', project), ('--project-directory', str(install)),
                                   ('--env-file', str(install / 'user.env'))):
                require(args.count(flag) == 1 and args[args.index(flag) + 1] == expected,
                        kind + ' missing/incorrect ' + flag)
            files = [args[i + 1] for i, arg in enumerate(args) if arg == '-f']
            expected = ['compose.docker.yml']
            if kind == 'init':
                expected += ['compose.docker.init-secrets.yml']
            expected += ['customer.override.yml']
            require(files == [str(install / x) for x in expected], kind + ' incorrect compose file order')
            arrays.append([str(HOST)] + args[2:])
        configs = []
        for kind, args in zip(('main', 'init'), arrays):
            rendered = folder / (letter + '.' + kind + '.json')
            yaml = folder / (letter + '.' + kind + '.yaml')
            config = canonical_yaml(yaml.read_text()) if yaml.exists() else json.loads(rendered.read_text())
            configs.append(config)
        main, boot = configs
        # Derive the base service set from current vendor Compose, not a count constant.
        base_args = [str(HOST), '--project-name', project, '--project-directory', str(install),
                     '--env-file', str(install / 'user.env'), '-f', str(install / 'compose.docker.yml')]
        base = render(base_args, folder, letter + '.base')
        require(set(main['services']) == set(base['services']), 'main services differ from current base')
        require('init-secrets' not in main['services'], 'main includes init-secrets')
        require(set(boot['services']) == set(base['services']) | {'init-secrets'}, 'bootstrap service set')
        bind_sources = set()
        for config in configs:
            require(config['name'] == project, 'top-level project name not overridden')
            for service in config['services'].values():
                require('container_name' not in service, 'fixed container_name prevents isolation')
                for volume in service.get('volumes', []):
                    if volume['type'] == 'bind':
                        source = Path(volume['source'])
                        require(source.is_absolute() and str(source).startswith(str(install) + os.sep),
                                'bind escapes own installation: ' + str(source))
                        require(os.path.realpath(source).startswith(str(install) + os.sep), 'bind symlink escapes root')
                        bind_sources.add(str(source))
        init_binds = {v['target']: v['source'] for v in boot['services']['init-secrets']['volumes']}
        require(init_binds == {'/secrets': str(install / 'secrets'), '/certs': str(install / 'nginx/certs')},
                'bootstrap bind sources')
        resources = set()
        for kind, key in (('volumes', 'studio-release'), ('networks', 'internal-network')):
            actual = main[kind][key]['name']
            require(actual == project + '_' + key, 'resource is not project-prefixed: ' + actual)
            require(boot[kind][key]['name'] == actual, 'bootstrap resource identity differs')
            resources.add(actual)
        svc = main['services']
        ports = {(str(p['published']), str(p['target'])) for p in svc['gw']['ports']}
        require(ports == {(values['TC_HTTP_PORT'], '80'), (values['TC_HTTPS_PORT'], '443')}, 'published ports')
        # There must be no additional published ports on any service.
        published = {str(p['published']) for service in svc.values() for p in service.get('ports', [])}
        require(published == {values['TC_HTTP_PORT'], values['TC_HTTPS_PORT']}, 'unexpected published ports')
        for key in ('TC_DB_NAME', 'AUTH_DB_NAME', 'GITEA_DB_NAME'):
            require(svc['db']['environment'][key] == values[key], 'db missing env ' + key)
        for service, key in (('auth-be', 'AUTH_DB_NAME'), ('tc-be', 'TC_DB_NAME')):
            environment = svc[service]['environment']
            require(environment['DB_DATABASE'] == values[key], service + ' DB_DATABASE')
            require(environment['DATABASE_URL'] == 'postgresql://lucy:dummy_db@db:5432/' + values[key],
                    service + ' DATABASE_URL')
        require(svc['git']['environment']['GITEA__database__NAME'] == values['GITEA_DB_NAME'], 'git DB name')
        templates = [v for v in svc['gw']['volumes'] if v['target'] == '/etc/nginx/templates/nginx.conf.template']
        expected = install / 'nginx' / ('nginx.conf' if letter == 'a' else 'nginx.http.conf')
        require(len(templates) == 1 and templates[0]['source'] == str(expected), 'gateway template override')
        unchanged_vendor(install)
        configurations.append((bind_sources, resources, published))
    for left, right, kind in zip(configurations[0], configurations[1], ('binds', 'resources', 'ports')):
        require(not left.intersection(right), 'two installations share ' + kind)
    print('accepted:', label, '(two source snapshots, actual document prefix, Compose config only)', flush=True)


def mutations(text):
    prefix = prefix_of(text)
    variants = []
    for flag, label in (('--project-directory', 'no-project-directory'), ('--project-name', 'no-project-name')):
        changed = re.sub(r'^.*' + re.escape(flag) + r'.*\n', '', prefix, flags=re.M)
        require(changed != prefix, 'mutation not applied: ' + label)
        variants.append((label, text.replace(prefix, changed, 1)))
    # Only the TC array loses its last override; leave TC_INIT intact.
    main, rest = prefix.split('TC_INIT=', 1)
    changed = main.replace(' -f "$INSTALL_ROOT/customer.override.yml"', '') + 'TC_INIT=' + rest
    require(changed != prefix, 'override mutation not applied')
    variants.append(('no-customer-override', text.replace(prefix, changed, 1)))
    variants.append(('update-bootstrap', text.replace('## 6. 이미지 버전 업데이트',
                    '## 6. 이미지 버전 업데이트\n\n```bash\n"${TC_INIT[@]}" run --rm init-secrets\n```', 1)))
    section = text.index('### 5.3 ')
    before, after = text[:section], text[section:]
    changed = re.sub(r'^test -f secrets/secrets.env.*\n', '', after, count=1, flags=re.M)
    require(changed != after, 'guard mutation not applied')
    variants.append(('no-secret-guard', before + changed))
    return variants


try:
    check_document(DOC, 'actual')
    for label, text in mutations(DOC.read_text()):
        document = LOG / (label + '.md')
        document.write_text(text)
        try:
            check_document(document, label)
        except AssertionError as error:
            (LOG / label / 'expected-failure.txt').write_text(str(error) + '\n')
            print('negative control rejected:', label, '-', error, flush=True)
        else:
            raise AssertionError('negative control unexpectedly PASSED: ' + label)
    print('All five negative controls rejected; no daemon, init, build, pull or service execution.', flush=True)
except Exception:
    traceback.print_exc()
    sys.exit(1)
PY
