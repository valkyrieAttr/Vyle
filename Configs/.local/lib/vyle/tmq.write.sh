#!/usr/bin/env bash

help_function() {
    cat <<EOF
$(basename "$0") [Flags] [Directory/Files]

Available Flags:
    --allow-pre             | PRE hooks only run if \$HYDE_TMQ_ALLOW_PRE is set to 1/true/yes
    --allow-warn            | Strict-Warnings: Exit if variables are malformed or don't exist in the ENV.
    --allow-debug           | Debug spit: set \$HYDE_TMQ_DEBUG=1 to enable verbose prints
    --allow-dry-run         | Dry-run: do not write files or execute RUN; just print actions

    --env        [S:P|E:V]  | Enables sourcing of a path (S:) or exporting a variable (E:).
                              Example: --env S: path/to/target E: foo=1
                              
    --proc             [N]  | Amount of CPU cores to be utilized for template generation. Default: 1
    
    --header [T:P:R:B = V]  | Override template header parameters on the fly. Accepts colon-separated key:value pair
                              Example: --header T:"/tmp/out" R:"echo Done"

                              'B' or implicit --buffer passes template data directly as a string or use '-' to read
                              from standard input (stdin). 
                                    Example: --header B:"path | <VAR>"
                                    Example: --header B:- --args
                              If T: is uninitialized, then it will fallback to /dev/null.

    --lock-timeout     [N]  | Seconds to wait for/make stale locks (sets \$HYDE_TMQ_LOCK_TIMEOUT). Default: 10
    
    --run-concurrency  [N]  | Cap parallel post-scripts under --defer-run (sets
                              \$HYDE_TMQ_RUN_CONCURRENCY). Default 1 = serial. 0 = fire-and-forget
                              (nohup, detached, not waited on -- logs kept, not auto-cleaned)
    
    --help                  | Show this help
    --file                  | Target path: path/to/template | path/to/dir..
    --dont-run              | Disable RUN execution (sets \$HYDE_TMQ_ALLOW_RUN=0)
    
    --pre-scan              | Pre-scan template file to avoid per-worker duplicate PRE invocation.
                              Runs unique PRE hooks once in parent and exports results to children

    --no-atomic             | Disable atomic writing (fsync/temp files) for faster direct writes while keeping locks.

    --defer-run             | Defer RUN/post-scripts: workers queue them instead of running them;
                              parent executes the queue after all workers finish (sets
                              \$HYDE_TMQ_DEFER_RUN=1)

    --compat-hyde           | Allow $ or \${} variables in template headers/hooks and disable <> in headers.

    --ignore-unbound        | Treat all <...> as literal markup, not placeholders: unbound plain
                              <VAR> is left as-is with no warning. Useful for large hand-authored
                              SVGs whose own tags (<g>, <defs>, ...) collide with the placeholder syntax.
                              Overridden by --allow-warn.

    --ignore-templates      | Space-separated list of filenames to skip when scanning directories.
    --disable-fallback      | Disable :- bash-style fallback-syntax in templates.

EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
    --allow-pre) export HYDE_TMQ_ALLOW_PRE=1 ;;
    --allow-warn) export HYDE_TMQ_STRICT=1 ;;
    --allow-debug) export HYDE_TMQ_DEBUG=1 ;;
    --allow-dry-run) export HYDE_TMQ_DRY_RUN=1 ;;
    --env)
        shift
        set -a
        env_mode=""
        while [[ "$#" -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            case "$1" in
            "E:")
                env_mode="E"
                ;;
            E:*)
                env_mode="E"
                export "${1#E:}"
                ;;
            "S:")
                env_mode="S"
                ;;
            S:*)
                env_mode="S"
                if [[ ! -e "${1#S:}" || -z "${1#S:}" ]]; then
                    printf '@[diagnostic:error(true)]: --env S: requires a valid file path (e.g., S: /path/to/target)\n' >&2
                    exit 2
                fi
                source "${1#S:}"
                ;;
            *)
                if [[ "$env_mode" == "E" ]]; then
                    export "$1"
                elif [[ "$env_mode" == "S" ]]; then
                    if [[ ! -e "$1" ]]; then
                        printf '@[diagnostic:error(true)]: --env chained path "%s" does not exist\n' "$1" >&2
                        exit 2
                    fi
                    source "$1"
                else
                    printf '@[diagnostic:error(true)]: --env arguments must begin with a valid S: or E: prefix\n' >&2
                    exit 2
                fi
                ;;
            esac
            shift
        done
        set +a
        continue
        ;;
    --proc)
        shift
        if [[ -z "${1:-}" || ! "${1}" =~ ^[0-9]+$ ]]; then
            printf '@[diagnostic:error(true)]: --proc requires a positive integer argument \n' >&2
            exit 2
        fi
        export HYDE_TMQ_PROC=$1
        ;;

    --header)
        shift
        HYDE_TMQ_HEADER_INIT=1
        while [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            case "$1" in
            T:*)
                export HYDE_TMQ_HEADER_TARGET="${1#T:}"
                ;;
            R:*)
                export HYDE_TMQ_HEADER_RUN="${1#R:}"
                ;;
            P:*)
                export HYDE_TMQ_HEADER_PRE="${1#P:}"
                ;;
            B:*)
                if [[ "${1#B:}" == "-" ]]; then
                    HYDE_TMQ_HEADER_BUFFER="$(cat)"
                else
                    HYDE_TMQ_HEADER_BUFFER="${1#B:}"
                fi
                export HYDE_TMQ_HEADER_BUFFER
                ;;
            *)
                printf '@[diagnostic:error(true)]: Invalid --header argument: %s\n' "$1" >&2
                ;;
            esac
            shift
        done
        continue
        ;;
    --lock-timeout)
        shift
        if [[ -z "${1:-}" || ! "$1" =~ ^[0-9]+$ ]]; then
            printf '@[diagnostic:error(true)]: --lock-timeout requires a positive integer argument\n' >&2
            exit 2
        fi
        export HYDE_TMQ_LOCK_TIMEOUT="$1"
        ;;
    --run-concurrency)
        shift
        if [[ -z "${1:-}" || ! "${1}" =~ ^[0-9]+$ ]]; then
            printf '@[diagnostic:error(true)]: --run-concurrency requires a non-negative integer argument\n' >&2
            exit 2
        fi
        export HYDE_TMQ_RUN_CONCURRENCY="$1"
        ;;
    --help)
        help_function
        exit 0
        ;;
    --file)
        shift
        while [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; do
            HYDE_TMQ_TEMPLATE_FILE="${HYDE_TMQ_TEMPLATE_FILE:+$HYDE_TMQ_TEMPLATE_FILE:}$1"
            shift
        done
        export HYDE_TMQ_TEMPLATE_FILE
        continue
        ;;
    --dont-run) export HYDE_TMQ_ALLOW_RUN=0 ;;
    --pre-scan) export HYDE_TMQ_PRE_SCAN=1 ;;
    --no-atomic) export HYDE_TMQ_NO_ATOMIC=1 ;;
    --defer-run) export HYDE_TMQ_DEFER_RUN=1 ;;
    --compat-hyde) export HYDE_TMQ_COMPAT_HYDE=1 ;;
    --ignore-unbound) export HYDE_TMQ_IGNORE_UNBOUND=1 ;;
    --disable-fallback) export HYDE_TMQ_DISABLE_FALLBACK=1 ;;
    --ignore-templates)
        shift
        if [[ -z "${1:-}" ]]; then
            printf '@[diagnostic:error(true)]: --ignore-templates argument requires file-paths'
            exit 2
        fi
        export HYDE_TMQ_IGNORE_TEMPLATES="$1"
        ;;

    *) break ;;
    esac
    shift
done

# Any remaining positional arguments are trailing Directory/File paths per
# the documented usage ("hyir.sh [Flags] [Directory/Files]"). Fold them into
# the same colon-joined list --file builds, so plain positional invocation
# works the same as passing --file explicitly.
if [[ $# -gt 0 ]]; then
    for _hyde_tmq_pos_arg in "$@"; do
        HYDE_TMQ_TEMPLATE_FILE="${HYDE_TMQ_TEMPLATE_FILE:+$HYDE_TMQ_TEMPLATE_FILE:}$_hyde_tmq_pos_arg"
    done
    unset _hyde_tmq_pos_arg
    export HYDE_TMQ_TEMPLATE_FILE
fi

if [[ -n "$HYDE_TMQ_HEADER_INIT" && "$HYDE_TMQ_HEADER_INIT" == 1 ]]; then
    if [[ -z "$HYDE_TMQ_HEADER_BUFFER" ]]; then
        printf '@[diagnostic:error(true)]: --header B:"" is required to be initialized. \n'
        exit 2
    fi

    if [[ "${HYDE_TMQ_PROC:-1}" -gt 1 ]]; then
        printf '@[diagnostic:warn(true)]: --header does not support multi-threading. Forcing --proc 1. \n'
    fi
    export HYDE_TMQ_PROC=1

    if [[ -n "$HYDE_TMQ_TEMPLATE_FILE" ]]; then
        printf '@[diagnostic:warn(true)]: Script argument --header with --file is not allowed!\n'
        exit 2
    fi

    if [[ -z "$HYDE_TMQ_HEADER_TARGET" ]]; then
        export HYDE_TMQ_HEADER_TARGET="/dev/null"
    fi

    if [[ -n "${HYDE_TMQ_HEADER_RUN:-}" && "${HYDE_TMQ_ALLOW_RUN:-1}" == 0 ]]; then
        printf '@[diagnostic:error(true)]: --header R:"" was provided but RUN hooks are not allowed due to --dont-run flag.\n'
        exit 2
    fi

    if [[ -n "${HYDE_TMQ_HEADER_PRE:-}" && "${HYDE_TMQ_ALLOW_PRE:-0}" != "1" ]]; then
        printf '@[diagnostic:error(true)]: --header pre="..." was provided but PRE hooks are not allowed. Please include the --allow-pre flag.\n' >&2
        exit 2
    fi

    if [[ -n "${HYDE_TMQ_RUN_CONCURRENCY:-}" ]]; then
        printf '@[diagnostic:error(true)]: Script argument --run-concurrency is not allowed when using --header.\n' >&2
        exit 2
    fi

    if [[ -n "${HYDE_TMQ_LOCK_TIMEOUT:-}" ]]; then
        printf '@[diagnostic:error(true)]: Script argument --lock-timeout is not allowed when using --header.\n' >&2
        exit 2
    fi

    if [[ "${HYDE_TMQ_DEFER_RUN:-0}" == 1 ]]; then
        printf '@[diagnostic:error(true)]: Script argument --defer-run is not allowed with --header (executes after generating the template anyway).\n' >&2
        exit 2
    fi

    if [[ "${HYDE_TMQ_PRE_SCAN:-0}" == 1 ]]; then
        printf '@[diagnostic:error(true)]: Script argument --pre-scan is not allowed with --header (not needed for a single file).\n' >&2
        exit 2
    fi
fi

set -eo pipefail
scrDir="$(dirname "$(realpath "$0")")"

export LIB_DIR="$scrDir"
# Only export XDG* if already set in the environment (don't override with empty)
[[ -n "${XDG_CACHE_HOME:-}" ]] && export XDG_CACHE_HOME
[[ -n "${XDG_CONFIG_HOME:-}" ]] && export XDG_CONFIG_HOME

export SCRIPT_NAME="$0"
export HYDE_TMQ_LOCK_DIR="${HYDE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hyde}/$(basename -- "${BASH_SOURCE[0]}" ".*")"
export HYDE_TMQ_LOCK_TIMEOUT="${HYDE_TMQ_LOCK_TIMEOUT:-10}"

perl - "$@" <<'EOF'
use strict;
use warnings;
use File::Find     qw(find);
use File::Path     qw(make_path);
use File::Basename qw(basename dirname);
use File::Spec;
use Time::HiRes qw(gettimeofday tv_interval);
use Fcntl       qw(:DEFAULT);
use IO::Handle;

my ( $LIB_DIR, $NPROC, $SCRIPT_NAME, $HOME_DIR, $PLACEHOLDER_RE );
my ( %REPLACE, %RGBA_BASE, %SKIP_SET, %made_dirs, @template_source,
    @INPUT_PATH, @files, %pids );
my ($raw,        $nl,         $header,      $body,
    $target,     $pre_script, $post_script, $post_is_run,
    $target_dir, $existing,   $found,       $n,
    $workers,    $chunk,      $res,         $queue_dir,
    $queue_fh
);

$LIB_DIR     = $ENV{LIB_DIR} // '';
$NPROC       = $ENV{HYDE_TMQ_PROC} || 1;
$SCRIPT_NAME = $ENV{SCRIPT_NAME} // '';
$SCRIPT_NAME = basename($SCRIPT_NAME) if length $SCRIPT_NAME;

@INPUT_PATH = split /:/, ( $ENV{HYDE_TMQ_TEMPLATE_FILE} // '' );
$HOME_DIR   = $ENV{HOME} // '';

# Control flags:

# PRE hooks only run if HYDE_TMQ_ALLOW_PRE is set to 1/true/yes
my $ALLOW_PRE = $ENV{HYDE_TMQ_ALLOW_PRE}
    && $ENV{HYDE_TMQ_ALLOW_PRE} =~ /^(1|true|yes)$/i ? 1 : 0;

# RUN is allowed unconditionally (per request). If you want to gate it later, set HYDE_TMQ_ALLOW_RUN similarly.
my $ALLOW_RUN = defined $ENV{HYDE_TMQ_ALLOW_RUN}
    && $ENV{HYDE_TMQ_ALLOW_RUN} =~ /^(0|false|no)$/i ? 0 : 1;

# Strict-Warnings: Exit if variables are malformed or doesn't exist in the ENV.
my $ALLOW_STRICT_WARNINGS = $ENV{HYDE_TMQ_STRICT}
    && $ENV{HYDE_TMQ_STRICT} =~ /^(1|true|yes)$/i ? 1 : 0;

# Dry-run: do not write files or execute RUN; just print actions
my $DRY_RUN = $ENV{HYDE_TMQ_DRY_RUN}
    && $ENV{HYDE_TMQ_DRY_RUN} =~ /^(1|true|yes)$/i ? 1 : 0;

# Debug spit: set HYDE_TMQ_DEBUG=1 to enable verbose prints
my $SPIT_DEBUG = $ENV{HYDE_TMQ_DEBUG}
    && $ENV{HYDE_TMQ_DEBUG} =~ /^(1|true|yes)$/i ? 1 : 0;

# Disable atomic file generation for faster direct writes
my $NO_ATOMIC = $ENV{HYDE_TMQ_NO_ATOMIC}
    && $ENV{HYDE_TMQ_NO_ATOMIC} =~ /^(1|true|yes)$/i ? 1 : 0;

# Pre-scan template file to avoid per-worker duplicate PRE invocation.
my $ALLOW_PRE_SCAN = $ENV{HYDE_TMQ_PRE_SCAN}
    && $ENV{HYDE_TMQ_PRE_SCAN} =~ /^(1|true|yes)$/i ? 1 : 0;

# Ignore-unbound: treat <...> as literal markup rather than placeholders.
# Unbound plain <VAR> is left as-is with no warning;
# --allow-warn (strict) takes precedence if both are set.
my $IGNORE_UNBOUND
    = $ENV{HYDE_TMQ_IGNORE_UNBOUND}
    && $ENV{HYDE_TMQ_IGNORE_UNBOUND} =~ /^(1|true|yes)$/i
    && !$ALLOW_STRICT_WARNINGS ? 1 : 0;

# Disable bash-style fallback
my $DISABLE_FALLBACK = $ENV{HYDE_TMQ_DISABLE_FALLBACK}
    && $ENV{HYDE_TMQ_DISABLE_FALLBACK} =~ /^(1|true|yes)$/i ? 1 : 0;

# Defer-run: workers queue expanded post-scripts to a per-process file
# instead of executing them; the parent runs the collected queue once all
# workers have exited.
my $DEFER_RUN = $ENV{HYDE_TMQ_DEFER_RUN}
    && $ENV{HYDE_TMQ_DEFER_RUN} =~ /^(1|true|yes)$/i ? 1 : 0;

my $RUN_CONCURRENCY
    = defined $ENV{HYDE_TMQ_RUN_CONCURRENCY}
    && $ENV{HYDE_TMQ_RUN_CONCURRENCY} =~ /^\d+$/
    ? int( $ENV{HYDE_TMQ_RUN_CONCURRENCY} )
    : 1;

# Compat-HyDE: Enable ${} signatures 
my $COMPAT_HYDE = $ENV{HYDE_TMQ_COMPAT_HYDE} && $ENV{HYDE_TMQ_COMPAT_HYDE} =~ /^(1|true|yes)$/i ? 1 : 0;

for my $path (@INPUT_PATH) {
    if ( -f $path ) {
        push @files, $path;
        $found = 1;
    }
    elsif ( -d $path ) {
        push @template_source, $path;
    }
}

unless ( @files || @template_source || $ENV{HYDE_TMQ_HEADER_BUFFER} ) {
    print
        "@[arg:no_arg]: No valid file or directory paths given. $SCRIPT_NAME --help for more information\n";
    exit(1);
}

if ( $> == 0 ) {
    printf( "@[root]: %s must not be run as root.\n", $SCRIPT_NAME );
    exit 1;
}

my $locks_base = $ENV{HYDE_TMQ_LOCK_DIR}
    || (
    $ENV{XDG_CACHE_HOME}
    ? "$ENV{XDG_CACHE_HOME}/.tmq/locks"
    : "$ENV{HOME}/.cache/tmq/locks"
    );

my $LOCK_TIMEOUT
    = $ENV{HYDE_TMQ_LOCK_TIMEOUT}
    ? int( $ENV{HYDE_TMQ_LOCK_TIMEOUT} )
    : 10;

# sanity: ensure locks base exists or can be created
unless ( -d $locks_base ) {
    eval { make_path($locks_base); 1 }
        or die
        "@[diagnostic:error:populate:write(false)]: Cannot create locks dir $locks_base: $!";
}

if ($DEFER_RUN) {
    $queue_dir = File::Spec->catdir( $locks_base, "queue-$$" );
    eval { make_path($queue_dir); 1 }
        or die
        "@[diagnostic:error:populate:write(false)]: Cannot create queue dir $queue_dir: $!";
}


# more permissive placeholder regex; captures color functions or simple names
# Allows a nested placeholder inside the fallback (e.g., <VAR:-<DEFAULT>>)
$PLACEHOLDER_RE
    = qr{<\s*(?:(\w+_rgba)\(\s*([^)]+)\s*\)|([\w-]+))\s*(?::-((?:<[^>]*>|[^>])+))?\s*>}x;

my $nested_content 
    = qr/(?: [^{}]++ | \{ (?: [^{}]++ | (?&HYIR_NEST) )* \} )*(?(DEFINE)(?<HYIR_NEST>\{ (?: [^{}]++ | (?&HYIR_NEST) )* \}))/x;

my $DOLLAR_RE 
    = qr{\$([a-zA-Z_]\w*)|\$\{\s*(?:(\w+)\(\s*([^)]+)\s*\)|([a-zA-Z_]\w*))\s*(?::-($nested_content))?\s*\}}x;

# sanitize environment: trim whitespace and escape quotes, but do not delete variables like PATH/HOME
sub sanitize_env {
    foreach my $key ( keys %ENV ) {
        my $value = $ENV{$key};
        $value =~ s/^\s+|\s+$//g;    # trim
        $ENV{$key} = $value;
    }
}

# Global cache to track pre-hooks that have already executed in this process
my %executed_pre_hooks;

# Track which (var, template_file) unbound-warnings have already been emitted
# in this process, so a placeholder repeated N times in one file doesn't
# produce N identical warn lines.
my %warned_unbound;

sub import_shell_env {
    my ($cmd) = @_;
    return unless $cmd;

    # Only import shell env if PRE hooks are explicitly allowed
    unless ($ALLOW_PRE) {
        warn
            "@[arg:allow_pre(false)]: Skipping pre-hook (HYDE_TMQ_ALLOW_PRE not enabled): $cmd\n";
        return;
    }

    # If this command ran already in this process, skip re-running it
    return if $executed_pre_hooks{$cmd}++;

    open my $fh, '-|', 'bash', '-c', "$cmd && env -0"
        or do {
        warn
            "@[diagnostic:error:arg:allow_pre(false)]: Failed pre-hook '$cmd': $!";
        return;
        };

    local $/ = "\0";
    my $env_changed = 0;

    while ( my $entry = <$fh> ) {
        chomp $entry;
        if ( $entry =~ /^([^=]+)=(.*)$/s ) {
            my ( $key, $val ) = ( $1, $2 );
            if ( !exists $ENV{$key} || $ENV{$key} ne $val ) {
                $ENV{$key} = $val;
                $env_changed = 1;
            }
        }
    }
    close $fh;

    if ($env_changed) {
        sanitize_env();
        build_env_cache();
    }
}

sub build_env_cache {
    %REPLACE = %RGBA_BASE = ();
    while ( my ( $k, $v ) = each %ENV ) {

        # permissive match for explicit rgba(R, G, B, A) strings
        if (   $k =~ /_rgba$/
            && $v
            =~ /rgba\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,/ )
        {
            $RGBA_BASE{$k} = "rgba($1,$2,$3,";
            $REPLACE{$k}   = $v;
            next;
        }

        if ( defined $v && $v =~ /^#?([0-9A-Fa-f]{6})$/ ) {
            my $hex = $1;
            my ( $r, $g, $b ) = (
                hex substr( $hex, 0, 2 ),
                hex substr( $hex, 2, 2 ),
                hex substr( $hex, 4, 2 )
            );
            my $rgba_key = $k . "_rgba";
            $RGBA_BASE{$rgba_key}
                = sprintf( "rgba(%d,%d,%d,", $r, $g, $b );
            $REPLACE{$rgba_key}
                = sprintf( "rgba(%d,%d,%d,1)", $r, $g, $b );
        }

        # default store the original variable
        $REPLACE{$k} = $v;
    }
}

build_env_cache();

my $current_lock;
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub {
    release_lock($current_lock) if defined $current_lock;
    exit 1;
};

sub fnv1a_hex {
    my ($str) = @_;
    my $hash = 0x811c9dc5;
    for my $byte ( unpack( 'C*', $str ) ) {
        $hash ^= $byte;
        $hash = ( $hash * 0x01000193 ) & 0xFFFFFFFF;
    }
    return sprintf( '%08x', $hash );
}

# Acquire a per-target mkdir-based lock. Returns lockdir path on success or dies on timeout.
sub acquire_lock {
    my ($target_path) = @_;
    my $hash          = fnv1a_hex($target_path);
    my $lockdir = File::Spec->catfile( $locks_base, "$hash.lock" );
    my $start   = time();

    while (1) {

        # Try to create directory atomically

        if ( mkdir $lockdir ) {

            # created lock successfully
            return $lockdir;
        }

        # If exists, check age and remove stale locks
        if ( -d $lockdir ) {
            my $age = time() - ( ( stat($lockdir) )[9] || 0 );
            if ( $age > $LOCK_TIMEOUT ) {
                warn
                    "@[atomic:remove:stale_lock(true)]: Removing stale lock $lockdir (age ${age}s)\n";
                rmdir $lockdir
                    ;    # attempt removal; next loop will try mkdir
                next;
            }
        }

        # check timeout
        if ( time() - $start > $LOCK_TIMEOUT ) {
            die
                "@[atomic:timeout(?)]: Timeout acquiring lock for $target_path (waited ${LOCK_TIMEOUT}s)\n";
        }
        select( undef, undef, undef, 0.05 );    # sleep 50ms
    }
}

sub release_lock {
    my ($lockdir) = @_;
    return unless $lockdir;
    if ( -d $lockdir ) {
        rmdir $lockdir
            or warn
            "@[atomic:release_lock(false)] Could not remove lock $lockdir: $!";
    }
}

sub fsync_or_warn {
    my ($fh) = @_;
    return unless defined $fh;

    # If the handle supports sync(), prefer it.
    if ( ref($fh) && $fh->can('sync') ) {
        eval { $fh->sync(); 1 } or do {
            warn "@[atomic:scan_status(failed)]: sync failed: $!\n"
                if $SPIT_DEBUG;
        };
        return;
    }

    # Otherwise try flush() (IO::Handle provides it)
    if ( ref($fh) && $fh->can('flush') ) {
        eval { $fh->flush(); 1 } or do {
            warn "@[atomic:fsync(failed)]: flush failed: $!\n"
                if $SPIT_DEBUG;
        };
        return;
    }

    warn
        "@[atomic:fsync_compatibility(unavailable)]: fsync/flush not available on this Perl build; durability not guaranteed\n"
        if $SPIT_DEBUG;
}

sub write_temp_file {
    my ( $t_dir, $content ) = @_;
    make_path($t_dir) unless -d $t_dir;

    my ( $fh, $tmp_path );
    my $attempts = 0;
    while (1) {
        $attempts++;
        my $candidate = File::Spec->catfile(
            $t_dir,
            sprintf(
                '.tmq_tmp.%d.%d.%d',
                $$, time(), int( rand(1e9) )
            )
        );
        if (sysopen(
                $fh, $candidate, O_CREAT | O_EXCL | O_RDWR, 0600
            )
            )
        {
            $tmp_path = $candidate;
            last;
        }
        die
            "Could not create a temp file in $t_dir after $attempts attempts: $!"
            if $attempts >= 100;
    }

    binmode $fh;
    print $fh $content;
    $fh->flush;
    fsync_or_warn($fh) unless $NO_ATOMIC;
    close $fh or die "Failed closing tmp file $tmp_path: $!";
    return $tmp_path;
}

# Atomic rename helper (rename tmp -> target)
sub rename_tmp_to_target {
    my ( $tmp_path, $target ) = @_;

    if ( -f $target ) {
        my $mode = ( stat($target) )[2] & 07777;
        chmod $mode, $tmp_path;
    }

    rename $tmp_path, $target or do {
        unlink $tmp_path if -f $tmp_path;
        die
            "@[atomic:rename_status(failure)]: Atomic rename failed: $!";
    };
}

sub direct_write_to_target {
    my ( $target, $content ) = @_;
    my $t_dir = dirname($target);
    make_path($t_dir) unless -d $t_dir;

    my $tmp = write_temp_file( $t_dir, $content );
    rename_tmp_to_target( $tmp, $target );
}

sub decode_escapes {
    my ($str) = @_;
    return '' unless defined $str;
    
    $str =~ s/\\([nrt0\\])/
        $1 eq 'n' ? "\n" :
        $1 eq 'r' ? "\r" :
        $1 eq 't' ? "\t" :
        $1 eq '0' ? "\0" :
        $1        # '\\' remains '\'
    /ge;
    
    return $str;
}

%SKIP_SET = map { $_ => 1 } (
    $ENV{HYDE_TMQ_IGNORE_TEMPLATES}
    ? split /\s+/,
        $ENV{HYDE_TMQ_IGNORE_TEMPLATES}
    : ()
);


my $braces = qr/\{.*?\}(?=;|\|\s*\$(?:RUN|PRE):)/s;
sub process_template {
    my ($template_file) = @_;

    if ($template_file eq '::BUFFER::') {
        $raw = decode_escapes($ENV{HYDE_TMQ_HEADER_BUFFER});
    }
    else {
        return unless -f $template_file;

        $raw = do {
            local $/;
            open my $fh, '<', $template_file
                or die
                "@[populate:open(true)]: Cannot open $template_file: $!";
            <$fh>;
        };
    }

    if ($DISABLE_FALLBACK) {
        while ( $raw =~ /$PLACEHOLDER_RE/g ) {
            if ( defined $4 ) {
                die
                    "@[diagnostic:arg:ignore_unbound(true)]: $template_file uses :- fallback syntax, which is disabled under --disable-fallback\n";
            }
        }

        if ($COMPAT_HYDE) {
            while ( $raw =~ /$DOLLAR_RE/g ) {
                if ( defined $5 ) {
                    die
                        "@[diagnostic:arg:ignore_unbound(true)]: $template_file uses \${...:-...} fallback syntax, which is disable under --disable-fallback \n";
                }
            }
        }
    }
    
    if ( $raw =~ /^(?<header>.*?(?:\|\s*\$(?:PRE|RUN):\s*(?:$braces|[^\n]*?(?=\|\s*\$(?:PRE|RUN):|\n|$)))+\s*?;?\s*?(?:\n|$))(?<body>.*)$/s) {
        $header = $+{header};
        $body = $+{body};
    }

    else {
        $nl     = index( $raw, "\n" );
        $header = $nl >= 0 ? substr( $raw, 0, $nl ) : $raw;
        $body = $nl >= 0 ? substr( $raw, $nl + 1 ) : '';

        if ( $header =~ /\|\s*\$(?:PRE|RUN):\s*\{/ ) {
            die "@[diagnostic:error:syntax(true)]: Hanging '{' detected in header of $template_file... Missing closing '}'\n";
        }
    }

    my $has_hooks = ( index( $header, '|' ) >= 0 );

    $header =~ s/^\s+|\s+$//g;

    my $replacer;
    my $dollar_replacer;
    $replacer = sub {
        my ( $rgba_base, $rgba_args, $var_name, $fallback ) = @_;

        my $resolve_fallback = sub {
            my ($fb) = @_;
            return undef unless defined $fb;
            $fb =~ s/^\s+|\s+$//g;

            $fb =~ s{$PLACEHOLDER_RE}{$replacer->($1, $2, $3, $4)}ge;
            return length($fb) ? $fb : undef;
        };

        if ( defined $var_name ) {
            return $REPLACE{$var_name} if exists $REPLACE{$var_name};

            my $fb_val = $resolve_fallback->($fallback);
            return $fb_val if defined $fb_val;

            return "<$var_name>" if $IGNORE_UNBOUND;

            if ($ALLOW_STRICT_WARNINGS) {
                die
                    "@[diagnostic:arg:strict_warn(true)]: Unbound variables <$var_name> in $template_file\n"
                    if $ALLOW_STRICT_WARNINGS;
            }
            else {
                warn
                    "@[diagnostic:warn(true)]: Unbound variables <$var_name> in $template_file; leaving as placeholder\n"
                    unless $warned_unbound{
                    "$var_name\0$template_file"}++;
                return "<$var_name>";
            }
        }
        else {
            return "$RGBA_BASE{$rgba_base}$rgba_args)"
                if exists $RGBA_BASE{$rgba_base};

            my $fb_val = $resolve_fallback->($fallback);
            return $fb_val if defined $fb_val;

            return "<$rgba_base>" if $IGNORE_UNBOUND;

            if ($ALLOW_STRICT_WARNINGS) {
                die
                    "@[diagnostic:arg:strict_warn(true)]: Unbound rgba variable <$rgba_base> in $template_file\n"
                    if $ALLOW_STRICT_WARNINGS;

                return "<$rgba_base>";
            }
            else {
                warn
                    "@[diagnostic:warn(true)]: Unbound rgba variable <$rgba_base> in $template_file; leaving as placeholder\n"
                    unless $warned_unbound{
                    "$rgba_base\0$template_file"}++;
                return "<$rgba_base>";
            }

        }
    };

    our $IS_HOOK_CONTEXT = 0;
    $dollar_replacer = sub {
        my ($var_bare, $func_base, $func_args, $var_brace, $fallback) = @_;
        my $var_name = $var_bare // $var_brace // $func_base;

        my $resolve_fallback = sub {
            my ($fb) = @_;
            return undef unless defined $fb;
            $fb =~ s/^\s+|\s+$//g;
            $fb =~ s{$DOLLAR_RE}{$dollar_replacer->($1, $2, $3, $4, $5)}ge;
            return length($fb) ? $fb : undef;
        };

        if ( defined $func_base ) {
            return "$RGBA_BASE{$func_base}$func_args)"
                if exists $RGBA_BASE{$func_base};
        }
        else {
            return $REPLACE{$var_name} if exists $REPLACE{$var_name};
        }

        my $fb_val = $resolve_fallback->($fallback);
        return $fb_val if defined $fb_val;

        my $orig;
        $orig = "\$$var_bare" if defined $var_bare;
        $orig = "\${$func_base($func_args)" . (defined $fallback ? ":-$fallback" : "") . "}" 
            if defined $func_base;
        $orig = "\${$var_brace" . (defined $fallback ? ":-$fallback" : "") . "}" 
            if !defined $var_bare;

        my $safe_orig = $IS_HOOK_CONTEXT ? "\\$orig" : $orig;
        return $safe_orig if $IGNORE_UNBOUND;

        if ($ALLOW_STRICT_WARNINGS) {
            die 
                "@[diagnostic:arg:strict_warn(true)]: Unbound variables $orig in $template_file \n";
        } else {
            warn 
                "@[diagnostic:warn(true)]: Unbound variables $orig in $template_file; leaving as placeholders\n"
                unless $warned_unbound{"$orig\0$template_file"}++;
            return $orig;
        }
    };

    ( $target, $pre_script, $post_script, $post_is_run )
        = ( '', '', '', 0 );

    if ($has_hooks && $template_file ne '::BUFFER::') {
        if ( $header
            =~ s/\|\s*\$PRE:\s*($braces|.*?);?(?=\s*\||$)//s )
        {
            $pre_script = $1;
            $pre_script =~ s/^\s+|\s+$//g;

            $pre_script =~ s/^\s*\{\s*//;
            $pre_script =~ s/\s*\}\s*;?\s*$//;
        }

        if ( $header =~ s/\|\s*\$RUN:(.*)$//s ) {
            $post_script = $1;
            $post_is_run = 1;
            $post_script =~ s/^\s+|\s+$//g;

            $post_script =~ s/^\s*\{\s*//;
            $post_script =~ s/\s*\}\s*;?\s*$//;
        }
        elsif ( $header =~ s/\|(.*)$//s ) {
            $post_script = $1;
            $post_script =~ s/^\s+|\s+$//g;

            $post_script =~ s/^\s*\{\s*//;
            $post_script =~ s/\s*\}\s*;?\s*$//;
        }

        # Whatever remains before the first pipe is the target
        $header =~ s/^\s+|\s+$//g;
        $header =~ s/\|$//;
        $target = $header;

    }
    elsif ($header) {

    # If header looks like a placeholder (<...>), or a path/filename,
    # treat it as the target. Otherwise treat the entire file as body.
        if ( $template_file eq '::BUFFER::') {
            $body = $raw;
        }
        elsif (   $header =~ $PLACEHOLDER_RE
            || $header =~ m{[\\/]}
            || $header !~ /\s/ )
        {
            $target = $header;
        }
        else {
            $body = $raw;    # Entire file is body
        }
    }
    else {
        $body = $raw;        # Entire file is body
    }

    $target = $ENV{HYDE_TMQ_HEADER_TARGET} if defined $ENV{HYDE_TMQ_HEADER_TARGET};
    $pre_script = $ENV{HYDE_TMQ_HEADER_PRE} if defined $ENV{HYDE_TMQ_HEADER_PRE};

    if (defined $ENV{HYDE_TMQ_HEADER_RUN}) {
        $post_script = $ENV{HYDE_TMQ_HEADER_RUN};
        $post_is_run = 1
    }

    # Execute Pre-Hook (only if allowed via HYDE_TMQ_ALLOW_PRE)
    if ($pre_script) {
        if ($COMPAT_HYDE) {
            die 
                "@[diagnostic:error:compat_hyde(true)]: Pre-hook cannot contain have <> when --compat-hyde is passed as an argument. \n" 
                if $target =~ /$PLACEHOLDER_RE/;
            {
                local $IS_HOOK_CONTEXT = 1;
                $pre_script =~ s{$DOLLAR_RE}{$dollar_replacer->($1, $2, $3, $4, $5)}ge 
                    if $pre_script =~ /\$/;
            }

        }
        else {
            $pre_script =~ s{$PLACEHOLDER_RE}{$replacer->($1, $2, $3, $4)}ge
                if $pre_script =~ /[<>()]/;
        }

        unless ( $ENV{HYDE_TMQ_PRE_SCAN_RAN} ) {
            import_shell_env($pre_script);
        }

        else {
            warn
                "@[diagnostic:warn:arg:pre_scan(true) - Prescan already ran; skipping PRE for $template_file\n]"
                if $SPIT_DEBUG;
        }
    }

    # Substitute placeholders in target, post_script, and body
    if ($target) {
        if ($COMPAT_HYDE) {
            die 
                "@[diagnostic:error:compat_hyde(true)]: Header <target> cannot have <VAR> syntax when --compat-hyde is passed as an argument. \n"
                if $target =~ /$PLACEHOLDER_RE/;
            
            $target =~ s{$DOLLAR_RE}{$dollar_replacer->($1, $2, $3, $4, $5)}ge 
                    if $target =~ /\$/;
        } else {
            $target =~ s{$PLACEHOLDER_RE}{$replacer->($1, $2, $3, $4)}ge
                if $target && $target =~ /[<>()]/;
        }
    }

    if ($post_script) {
        if ($COMPAT_HYDE) {
            die 
                "@[diagnostic:error:compat_hyde(true)]: Header RUN: hook cannot have <VAR> syntax when --compat-hyde is passed as an argument. \n"
                if $post_script =~ /$PLACEHOLDER_RE/;
            {
                local $IS_HOOK_CONTEXT = 1;
                $post_script =~ s{$DOLLAR_RE}{$dollar_replacer->($1, $2, $3, $4, $5)}ge 
                    if $post_script =~ /\$/;
            }
        } else {
            $post_script =~ s{$PLACEHOLDER_RE}{$replacer->($1, $2, $3, $4)}ge
                if $post_script && $post_script =~ /[<>()]/;
        }
    }

    $body =~ s{$PLACEHOLDER_RE}{$replacer->($1, $2, $3, $4)}ge
        if $body && $body =~ /[<>()]/;

    unless ( defined $target && length $target ) {
        print
            "@[arg:empty_path(true)] No target specified in $template_file; skipping\n"
            if $SPIT_DEBUG;
        return;
    }

    $target_dir = dirname($target);

    if ( $target_dir && $target_dir ne '' && $target_dir ne '.' ) {
        unless ( $made_dirs{$target_dir}++ ) {
            make_path($target_dir) unless -d $target_dir;
        }
    }

    $existing = "";
    my $file_exists = 0;

    if ( -f $target ) {
        $existing = do {
            local $/;
            open my $fh, '<', $target
                or die
                "@[populate:error(true)]: Cannot read $target: $!";
            <$fh>;
        };
        $file_exists = 1;
    }

    my $contents_changed = ( $existing ne $body );
    my $needs_write      = ( !$file_exists || $contents_changed );

    if ($needs_write) {
        if ($DRY_RUN) {
            print
                "@[arg:dry_run(true)]: Would populate $target <- $template_file\n"
                if $SPIT_DEBUG;
        }
        else {
            if ($NO_ATOMIC) {

                # Direct write under lock (faster, less durable). Acquire lock first.
                eval {
                    $current_lock = acquire_lock($target);
                    direct_write_to_target( $target, $body );
                    1;
                } or do {
                    my $err
                        = $@ || "Unknown error during direct write";
                    warn
                        "@[populate:error(true)]: Failed writing $target directly: $err";
                    release_lock($current_lock)
                        if defined $current_lock;
                    die $err;
                };
                release_lock($current_lock) if defined $current_lock;
            }
            else {
                # Atomic path: prepare tmp (with optional fsync), then lock and rename.
                my $tmp_path;
                eval {
                    $tmp_path = write_temp_file( $target_dir, $body );
                    1;
                } or do {
                    my $err = $@ || "Unknown error preparing tmp";
                    warn
                        "@[populate:error(true)]: Failed preparing tmp for $target: $err";
                    unlink $tmp_path
                        if defined $tmp_path && -f $tmp_path;
                    die $err;
                };

                eval {
                    $current_lock = acquire_lock($target);
                    rename_tmp_to_target( $tmp_path, $target );
                    1;
                } or do {
                    my $err
                        = $@ || "Unknown error during locked rename";
                    warn
                        "@[populate:error(true)]: Failed writing $target: $err";
                    unlink $tmp_path
                        if defined $tmp_path && -f $tmp_path;
                    release_lock($current_lock)
                        if defined $current_lock;
                    die $err;
                };

                release_lock($current_lock) if defined $current_lock;
            }
        }
    }

    if ( $post_script && $ALLOW_RUN ) {
        if ($DRY_RUN) {
            print
                "@[arg:dry_run(true)]: Would run post-script: $post_script\n"
                if $SPIT_DEBUG;
        }
        elsif ($DEFER_RUN) {
            enqueue_post_script(
                $queue_fh,      $post_is_run,
                $template_file, $post_script
            );
            print
                "@[defer_run:queued(true)]: Queued post-script from $template_file\n"
                if $SPIT_DEBUG;
        }
        else {
            if ($post_is_run) {
                system($post_script) == 0
                    or warn
                    "@[execution:error(true)]: Failed to execute $post_script from $template_file: $?";
            }
            elsif ( -x $post_script ) {
                system($post_script) == 0
                    or warn
                    "@[execution:error(true)]: Failed to execute $post_script from $template_file";
            }
            else {
                print
                    "@[execution(false)]: Theme Control - Skipped non-executable script from $template_file\n"
                    if $SPIT_DEBUG;
            }
        }
    }

    if ($SPIT_DEBUG) {
        if ($needs_write) {
            print
                "@[populate:write(true)]: $target <- $template_file\n";
        }
        else {
            print
                "@[populate:write(false)]: Skipped changing $target <- $template_file\n";
        }
    }

}

sub enqueue_post_script {
    my ( $fh, $is_run, $source, $cmd ) = @_;
    return unless $fh;
    print $fh join( "\0", ( $is_run ? 1 : 0 ), $source, $cmd ), "\0";
}

# Called from the parent after all workers have exited: read every
# *.queue file back into a list of { is_run, source, cmd } hashrefs, in a
# stable filename-sorted order.
sub read_queue_dir {
    my ($dir) = @_;
    my @items;

    return @items unless opendir( my $dh, $dir );
    my @qfiles = sort grep {/\.queue$/} readdir $dh;
    closedir $dh;

    for my $qfile (@qfiles) {
        my $path = File::Spec->catfile( $dir, $qfile );
        next unless -f $path;

        open my $fh, '<', $path or do {
            warn
                "@[diagnostic:error(true)]: Cannot read queue file $path: $!\n";
            next;
        };
        local $/ = "\0";
        my @fields;
        while ( my $chunk = <$fh> ) {
            chomp $chunk;
            push @fields, $chunk;
            if ( @fields == 3 ) {
                push @items,
                    {
                    is_run => $fields[0],
                    source => $fields[1],
                    cmd    => $fields[2]
                    };
                @fields = ();
            }
        }
        warn
            "@[diagnostic:warn(true)]: Discarding incomplete queue record in $path\n"
            if @fields && $SPIT_DEBUG;
        close $fh;
    }

    return @items;
}

sub execute_post_script {
    my ( $cmd, $is_run, $source ) = @_;

    if ($is_run) {
        system($cmd) == 0 or do {
            warn
                "@[execution:error(true)]: Failed to execute $cmd from $source: $?\n";
            return 0;
        };
    }
    elsif ( -x $cmd ) {
        system($cmd) == 0 or do {
            warn
                "@[execution:error(true)]: Failed to execute $cmd from $source\n";
            return 0;
        };
    }
    else {
        print
            "@[execution(false)]: Theme Control - Skipped non-executable script from $source\n"
            if $SPIT_DEBUG;
    }
    return 1;
}

sub run_queue_serial {
    my ($items) = @_;
    my $any_failed = 0;
    for my $item (@$items) {
        execute_post_script( $item->{cmd}, $item->{is_run},
            $item->{source} )
            or $any_failed = 1;
    }
    return $any_failed;
}

# Policy: bounded concurrency. A rolling fork pool of at most $concurrency
# children; each child runs and is waited on for exactly one post-script.
sub run_queue_concurrent {
    my ( $items, $concurrency ) = @_;
    my @pending = @$items;
    my %running;
    my $any_failed = 0;

    while ( @pending || %running ) {
        while ( @pending && scalar( keys %running ) < $concurrency ) {
            my $item = shift @pending;
            my $pid  = fork;
            if ( !defined $pid ) {
                warn
                    "@[diagnostic:error:fork:run(false)]: Fork failed for deferred post-script, running inline: $!\n";
                execute_post_script( $item->{cmd}, $item->{is_run},
                    $item->{source} )
                    or $any_failed = 1;
                next;
            }
            if ( $pid == 0 ) {
                my $ok = execute_post_script( $item->{cmd},
                    $item->{is_run}, $item->{source} );
                exit( $ok ? 0 : 1 );
            }
            $running{$pid} = 1;
        }

        last unless %running;

        my $p = wait();
        if ( $p > 0 ) {
            $any_failed = 1 if ( $? >> 8 ) != 0;
            delete $running{$p};
        }
    }
    return $any_failed;
}

sub run_queue_background {
    my ($items) = @_;
    execute_post_script_background( $_->{cmd}, $_->{is_run},
        $_->{source} )
        for @$items;
    return 0; # outcome unknown by design; never fails the overall run
}

sub execute_post_script_background {
    my ( $cmd, $is_run, $source ) = @_;

    unless ( $is_run || -x $cmd ) {
        print
            "@[execution(false)]: Theme Control - Skipped non-executable script from $source\n"
            if $SPIT_DEBUG;
        return;
    }

    my $log = "$ENV{HYDE_TMQ_LOCK_DIR}/nohup.out"; 

    system("nohup $cmd >>'$log' 2>&1 &");

    warn
        "@[defer_run:background(true)]: Backgrounded post-script from $source (log: $log)\n"
        if $SPIT_DEBUG;
}

find(
    {   wanted => sub {
            return
                unless -f && /\.(dcol|theme)$/
                && !exists $SKIP_SET{ basename($_) };
            $found = 1;
            push @files, $File::Find::name;
        },
        no_chdir => 1,
    },
    @template_source
);

unless ($found || defined $ENV{HYDE_TMQ_HEADER_BUFFER}) {
    printf(
        "@[stream:file_capture(false)]: %s: no .dcol templates found, nothing to apply.\n",
        $SCRIPT_NAME );
    exit 1;
}

@files = map { $_->[0] }
    sort {
        my ( $ap, $bp ) = ( $a->[1], $b->[1] );
        $res = 0;
        for ( my $i = 0; $i < @$ap && $i < @$bp; $i++ ) {
            $res
                = $ap->[$i] =~ /^\d+$/ && $bp->[$i] =~ /^\d+$/
                ? ( $ap->[$i] <=> $bp->[$i] )
                : ( lc( $ap->[$i] ) cmp lc( $bp->[$i] ) );
            last if $res;
        }
        $res || scalar(@$ap) <=> scalar(@$bp);
    }
    map {
        [ $_, [ map { /^\d+$/ ? $_ : lc($_) } split /(\d+)/, $_ ] ]
    } @files;

if (defined $ENV{HYDE_TMQ_HEADER_BUFFER}) {
    push @files, '::BUFFER::';
    $found = 1;
}

if ($ALLOW_PRE_SCAN) {
    unless ($ALLOW_PRE) {
        die
            "@[arg:required_flag(--allow-pre)]: Pre-scan requested but PRE is not allowed. Set \$HYDE_TMQ_ALLOW_PRE=1.\n";

    }

    my %seen_pre;
    foreach my $f (@files) {
        my $hdr = "";

        if ($f eq '::BUFFER::') {
            my $raw_buf = decode_escapes($ENV{HYDE_TMQ_HEADER_BUFFER});

            if ($raw_buf =~ /^(?<header>.*?(?:\|\s*\$(?:PRE|RUN):\s*(?:$braces|[^\n]*?(?=\|\s*\$(?:PRE|RUN):|\n|$)))+\s*?;?\s*?(?:\n|$))(?<body>.*)$/s) {
                $hdr = $+{header};
            } else {
                my $nl_idx = index($raw_buf, "\n");
                $hdr = $nl_idx >= 0 ? substr($raw_buf, 0, $nl_idx) : $raw_buf;
                
                if ( $hdr =~ /\|\s*\$(?:PRE|RUN):\s*\{/ ) {
                    die "@[diagnostic:error:syntax(true)]: Hanging '{' detected ... Missing closing '}'\n";

                }
            }

            $hdr =~ s/^\s+|\s+$//g;
        }
        else {
            next unless -f $f;
            if ( open my $fh, '<', $f ) {
                local $/;
                my $full_raw = <$fh> // "";
                close $fh;

                if ($full_raw =~ /^(?<header>.*?(?:\|\s*\$(?:PRE|RUN):\s*(?:$braces|[^\n]*?(?=\|\s*\$(?:PRE|RUN):|\n|$)))+\s*?;?\s*?(?:\n|$))(?<body>.*)$/s) {
                    $hdr = $+{header};
                } else {
                    my $nl_idx = index($full_raw, "\n");
                    $hdr = $nl_idx >= 0 ? substr($full_raw, 0, $nl_idx) : $full_raw;
                }
                $hdr =~ s/^\s+|\s+$//g;
            }
        }

        my $pre = "";
        if ( $hdr =~ /\|\s*\$PRE:\s*($braces|.*?);?(?=\s*\||$)/s ) {
            $pre = $1;
            $pre =~ s/^\s+|\s+$//g;

            $pre =~ s/^\s*\{\s*//;
            $pre =~ s/\s*\}\s*;?\s*$//;
        }

        next unless $pre;
        unless ( $seen_pre{$pre}++ ) {
            warn
                "@[active:arg:flag(--pre-scan)]: Running PRE - $pre \n"
                if $SPIT_DEBUG;
            import_shell_env($pre);
        }
    }

    $ENV{HYDE_TMQ_PRE_SCAN_RAN} = 1;
    build_env_cache();
}

$n       = scalar @files;
$workers = $n < $NPROC ? $n : $NPROC;
$chunk   = int( ( $n + $workers - 1 ) / $workers ); # ceiling division

my $t0 = [gettimeofday];

for ( my $i = 0; $i < $n; $i += $chunk ) {
    my $end = $i + $chunk - 1;
    $end = $n - 1 if $end >= $n;

    my $pid = fork // die "Fork failed: $!";
    if ( $pid == 0 ) {
        eval {
            if ($DEFER_RUN) {
                my $qfile
                    = File::Spec->catfile( $queue_dir, "$$.queue" );
                open $queue_fh, '>', $qfile
                    or die
                    "@[diagnostic:error:populate:write(false)]: Cannot create queue file $qfile: $!\n";
                binmode $queue_fh;
            }
            process_template( $files[$_] ) for $i .. $end;
            1;
        } or do {
            warn
                "@[diagnostic:error:fork:worker(false)]: Worker encountered an error: \n\t$@";
            close $queue_fh if $queue_fh;
            exit 1;
        };
        close $queue_fh if $queue_fh;
        exit 0;
    }
    $pids{$pid} = 1;
}

# Wait for children and record failures
my $failed = 0;
while ( scalar keys %pids ) {
    my $p = wait();
    last if $p == -1;

    if ( $p > 0 ) {
        my $status = $? >> 8;
        $failed = 1 if $status != 0;
        delete $pids{$p};
    }
}

if ($DEFER_RUN) {
    my @queued = read_queue_dir($queue_dir);

    if (@queued) {
        warn sprintf(
            "@[defer_run:queue(true)]: Running %d deferred post-script(s)\n",
            scalar @queued )
            if $SPIT_DEBUG;

        my $run_failed
            = $RUN_CONCURRENCY == 0 ? run_queue_background( \@queued )
            : $RUN_CONCURRENCY > 1
            ? run_queue_concurrent( \@queued, $RUN_CONCURRENCY )
            : run_queue_serial( \@queued );
        $failed = 1 if $run_failed;
    }

    if ( opendir my $dh, $queue_dir ) {
        unlink File::Spec->catfile( $queue_dir, $_ )
            for grep {/\.queue$/} readdir $dh;
        closedir $dh;
    }
    rmdir $queue_dir;
}

if ( $failed == 0 ) {
    my $elapsed = tv_interval($t0);
    printf(
        "@[diagnostic:telemetry(On)]: Rendered %d templates using %d workers in %.4f seconds.\n",
        $n, $workers, $elapsed )
        if $SPIT_DEBUG;
}
exit( $failed ? 1 : 0 );
EOF
