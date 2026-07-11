#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Local RK3588 DW HDMI QP audio packet diagnostic runner.
# This is hardware test tooling, not a stable kernel userspace ABI.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
KERNEL_TREE=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)
CARD=${RK3588_HDMI_AUDIO_CARD:-hdmi0}
PCM_DEVICE=${RK3588_HDMI_AUDIO_PCM:-0}
DURATION=${RK3588_HDMI_AUDIO_DURATION:-8}
RESULT_PARENT=${RK3588_HDMI_AUDIO_RESULTS:-$PWD}
SYSFS_DIR=${RK3588_HDMI_AUDIO_SYSFS:-}
I2S_SYSFS_DIR=${RK3588_HDMI_I2S_SYSFS:-}
PREFILL_PARAM=/sys/module/snd_soc_rockchip_i2s_tdm/parameters/tx_fifo_prefill_us
PROC_PCM=/proc/asound/$CARD/pcm${PCM_DEVICE}p/sub0
RUNNER_PID=

usage()
{
	cat <<EOF
Usage: $0 baseline
       $0 matrix
       $0 run CASE [auto|0|1] [auto|0xNNNN] [current|0-20] [FORMAT]
       $0 status
       $0 restore
       $0 list

Cases: 8ch-48k 2ch-96k 4ch-96k 4ch-96k-s16 8ch-96k
       2ch-192k 2ch-192k-s16 8ch-192k

FORMAT may be S16_LE, S24_LE, or S32_LE; the case default is S32_LE.

Environment:
  RK3588_HDMI_AUDIO_CARD       ALSA card ID (default: hdmi0)
  RK3588_HDMI_AUDIO_PCM        ALSA PCM device (default: 0)
  RK3588_HDMI_AUDIO_DURATION   seconds per case (default: 8)
  RK3588_HDMI_AUDIO_RESULTS    parent result directory (default: current)
  RK3588_HDMI_AUDIO_SYSFS      explicit HDMI diagnostic sysfs directory
  RK3588_HDMI_I2S_SYSFS        explicit Rockchip I2S sysfs directory
EOF
}

die()
{
	echo "error: $*" >&2
	exit 1
}

need_command()
{
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

discover_hdmi_sysfs()
{
	local attr
	local -a candidates=()

	if [[ -n $SYSFS_DIR ]]; then
		[[ -e $SYSFS_DIR/audio_debug_status ]] ||
			die "no audio_debug_status below $SYSFS_DIR"
		return
	fi

	shopt -s nullglob
	for attr in /sys/bus/platform/devices/*/audio_debug_status; do
		candidates+=("${attr%/audio_debug_status}")
	done
	shopt -u nullglob

	((${#candidates[@]})) || die "no DW HDMI QP audio diagnostics found"

	for SYSFS_DIR in "${candidates[@]}"; do
		if [[ $SYSFS_DIR == *fde80000.hdmi ]]; then
			return
		fi
	done

	if ((${#candidates[@]} == 1)); then
		SYSFS_DIR=${candidates[0]}
		return
	fi

	die "multiple HDMI diagnostic devices found; set RK3588_HDMI_AUDIO_SYSFS"
}

discover_i2s_sysfs()
{
	local dir

	if [[ -n $I2S_SYSFS_DIR ]]; then
		return
	fi

	for dir in /sys/bus/platform/devices/fddf0000.i2s \
		   /sys/bus/platform/devices/*fddf0000*i2s*; do
		if [[ -d $dir ]]; then
			I2S_SYSFS_DIR=$dir
			return
		fi
	done
}

restore_auto()
{
	if [[ -n $SYSFS_DIR && -e $SYSFS_DIR/audio_debug_layout ]]; then
		echo auto > "$SYSFS_DIR/audio_debug_layout" || true
		echo auto > "$SYSFS_DIR/audio_debug_sample_present" || true
	fi
}

stop_runner()
{
	if [[ -n $RUNNER_PID ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
		kill "$RUNNER_PID" 2>/dev/null || true
		wait "$RUNNER_PID" 2>/dev/null || true
	fi
	RUNNER_PID=
}

cleanup()
{
	stop_runner
	restore_auto
}

case_parameters()
{
	FORMAT=S32_LE

	case $1 in
	8ch-48k)
		CHANNELS=8
		RATE=48000
		;;
	2ch-96k)
		CHANNELS=2
		RATE=96000
		;;
	4ch-96k)
		CHANNELS=4
		RATE=96000
		;;
	4ch-96k-s16)
		CHANNELS=4
		RATE=96000
		FORMAT=S16_LE
		;;
	8ch-96k)
		CHANNELS=8
		RATE=96000
		;;
	2ch-192k)
		CHANNELS=2
		RATE=192000
		;;
	2ch-192k-s16)
		CHANNELS=2
		RATE=192000
		FORMAT=S16_LE
		;;
	8ch-192k)
		CHANNELS=8
		RATE=192000
		;;
	*)
		die "unknown case: $1"
		;;
	esac
}

wait_for_running()
{
	local i

	for ((i = 0; i < 200; i++)); do
		if [[ -r $PROC_PCM/status ]] &&
		   grep -q '^state: RUNNING' "$PROC_PCM/status"; then
			return
		fi
		if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
			return 1
		fi
		sleep 0.01
	done

	return 1
}

capture_file()
{
	local source=$1
	local destination=$2

	if [[ -r $source ]]; then
		if ! cat "$source" > "$destination" 2>&1; then
			echo "read failed: $source" >> "$destination"
		fi
	else
		echo "unavailable: $source" > "$destination"
	fi
}

capture_snapshot()
{
	local case_dir=$1
	local label=$2
	local snapshot=$case_dir/$label

	mkdir -p "$snapshot"
	date --iso-8601=ns > "$snapshot/time"
	capture_file "$PROC_PCM/hw_params" "$snapshot/alsa-hw_params"
	capture_file "$PROC_PCM/status" "$snapshot/alsa-status"
	capture_file "$SYSFS_DIR/audio_debug_status" \
		"$snapshot/qp-audio-debug-status"
	capture_file "$SYSFS_DIR/audio_debug_layout" \
		"$snapshot/qp-configured-layout"
	capture_file "$SYSFS_DIR/audio_debug_sample_present" \
		"$snapshot/qp-configured-sample-present"
	capture_file "$PREFILL_PARAM" "$snapshot/i2s-tx-fifo-prefill-us"

	if [[ -n $I2S_SYSFS_DIR ]]; then
		capture_file "$I2S_SYSFS_DIR/power/runtime_status" \
			"$snapshot/i2s-runtime-status"
		capture_file "$I2S_SYSFS_DIR/uevent" "$snapshot/i2s-uevent"
	else
		echo "Rockchip I2S platform device not found" > \
			"$snapshot/i2s-runtime-status"
	fi

	dmesg | grep -E 'rockchip-i2s-tdm|fddf0000\.i2s|dwhdmiqp-rockchip|fde80000\.hdmi' \
		> "$snapshot/kernel-audio-messages" || true
}

run_case()
{
	local name=$1
	local layout=${2:-auto}
	local sample_present=${3:-auto}
	local prefill=${4:-current}
	local format_override=${5:-}
	local active_prefill=unavailable
	local timestamp
	local case_dir
	local rc

	case_parameters "$name"
	if [[ -n $format_override ]]; then
		FORMAT=$format_override
	fi
	[[ $FORMAT == S16_LE || $FORMAT == S24_LE || $FORMAT == S32_LE ]] ||
		die "format must be S16_LE, S24_LE, or S32_LE"
	[[ $layout == auto || $layout =~ ^[01]$ ]] ||
		die "layout must be auto, 0, or 1"
	[[ $sample_present == auto ||
	   $sample_present =~ ^0[xX][[:xdigit:]]{1,4}$ ]] ||
		die "Sample_Present must be auto or a 16-bit hexadecimal value"
	[[ $prefill == current || $prefill =~ ^([0-9]|1[0-9]|20)$ ]] ||
		die "TX FIFO prefill must be current or an integer from 0 through 20"
	if [[ -e $PREFILL_PARAM ]]; then
		if [[ $prefill != current ]]; then
			echo "$prefill" > "$PREFILL_PARAM"
		fi
		active_prefill=$(<"$PREFILL_PARAM")
	elif [[ $prefill != current ]]; then
		die "TX FIFO prefill control is unavailable"
	fi
	timestamp=$(date '+%Y%m%d-%H%M%S')
	case_dir=$RESULT_ROOT/${timestamp}-${name}-format-${FORMAT}-layout-${layout}
	case_dir+=-sp-${sample_present}-prefill-${active_prefill}
	case_dir=${case_dir//0x/}
	mkdir -p "$case_dir"

	echo "$layout" > "$SYSFS_DIR/audio_debug_layout"
	echo "$sample_present" > "$SYSFS_DIR/audio_debug_sample_present"

	{
		echo "case=$name"
		echo "channels=$CHANNELS"
		echo "rate=$RATE"
		echo "format=$FORMAT"
		echo "layout=$layout"
		echo "sample_present=$sample_present"
		echo "tx_fifo_prefill_us=$active_prefill"
		echo "sysfs=$SYSFS_DIR"
		echo "i2s_sysfs=${I2S_SYSFS_DIR:-unavailable}"
		echo "pcm=hw:CARD=$CARD,DEV=$PCM_DEVICE"
		uname -a
		if git -C "$KERNEL_TREE" rev-parse --is-inside-work-tree \
				>/dev/null 2>&1; then
			echo "kernel_git=$(git -C "$KERNEL_TREE" rev-parse HEAD)"
		fi
	} > "$case_dir/metadata"

	iecset -D "hw:$CARD" aud on rat 0 > "$case_dir/iecset" 2>&1
	echo 1 > "$SYSFS_DIR/audio_debug_clear_errors"

	echo "running $name layout=$layout sample_present=$sample_present prefill=$active_prefill"
	timeout --signal=TERM --kill-after=1 "$DURATION" \
		speaker-test -D "hw:CARD=$CARD,DEV=$PCM_DEVICE" \
		-F "$FORMAT" -c "$CHANNELS" -r "$RATE" -t sine \
		> "$case_dir/speaker-test.log" 2>&1 &
	RUNNER_PID=$!

	if ! wait_for_running; then
		capture_snapshot "$case_dir" failed-before-running
		stop_runner
		die "$name did not reach ALSA RUNNING; see $case_dir"
	fi

	sleep 0.1
	kill -0 "$RUNNER_PID" 2>/dev/null || die "$name exited before 100 ms"
	capture_snapshot "$case_dir" 0100ms
	sleep 0.2
	kill -0 "$RUNNER_PID" 2>/dev/null || die "$name exited before 300 ms"
	capture_snapshot "$case_dir" 0300ms
	sleep 0.7
	kill -0 "$RUNNER_PID" 2>/dev/null || die "$name exited before one second"
	capture_snapshot "$case_dir" 1000ms
	sleep 2
	kill -0 "$RUNNER_PID" 2>/dev/null || die "$name exited before three seconds"
	capture_snapshot "$case_dir" 3000ms

	set +e
	wait "$RUNNER_PID"
	rc=$?
	set -e
	RUNNER_PID=

	if ((rc != 0 && rc != 124)); then
		die "$name failed with status $rc; see $case_dir"
	fi
}

run_baseline()
{
	local automatic=auto

	run_case 8ch-48k "$automatic" "$automatic"
	run_case 2ch-96k "$automatic" "$automatic"
	run_case 4ch-96k "$automatic" "$automatic"
	run_case 8ch-96k "$automatic" "$automatic"
	run_case 2ch-192k "$automatic" "$automatic"
}

run_matrix()
{
	run_baseline

	run_case 4ch-96k 1 auto
	run_case 4ch-96k auto 0x0003
	run_case 4ch-96k 1 0x0003

	run_case 8ch-96k 1 auto
	run_case 8ch-96k auto 0x000f
	run_case 8ch-96k 1 0x000f

	run_case 2ch-192k 0 auto
	run_case 2ch-192k auto 0x000f
	run_case 2ch-192k 0 0x000f
}

command=${1:-}
[[ -n $command ]] || {
	usage
	exit 1
}

case $command in
-h|--help)
	usage
	exit 0
	;;
list)
	echo '8ch-48k 2ch-96k 4ch-96k 4ch-96k-s16 8ch-96k'
	echo '2ch-192k 2ch-192k-s16 8ch-192k'
	exit 0
	;;
baseline|matrix|run|status|restore)
	;;
*)
	usage
	die "unknown command: $command"
	;;
esac

((EUID == 0)) || die "run as root so sysfs and kernel logs are accessible"
discover_hdmi_sysfs
[[ -w $SYSFS_DIR/audio_debug_layout ]] ||
	die "diagnostic controls below $SYSFS_DIR are not writable"

if [[ $command == baseline || $command == matrix || $command == run ]]; then
	need_command iecset
	need_command speaker-test
	need_command timeout
	discover_i2s_sysfs
	[[ -d $PROC_PCM ]] ||
		die "missing ALSA PCM state directory: $PROC_PCM"
	[[ $DURATION =~ ^[0-9]+$ ]] && ((DURATION >= 4)) ||
		die "RK3588_HDMI_AUDIO_DURATION must be an integer of at least 4"

	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
fi

case $command in
restore)
	restore_auto
	echo "restored automatic Layout and Sample_Present generation"
	;;
status)
	cat "$SYSFS_DIR/audio_debug_layout"
	cat "$SYSFS_DIR/audio_debug_sample_present"
	cat "$SYSFS_DIR/audio_debug_status"
	;;
run)
	[[ $# -ge 2 && $# -le 6 ]] ||
		die "run requires CASE [LAYOUT] [SAMPLE_PRESENT] [PREFILL_US] [FORMAT]"
	RESULT_ROOT=$RESULT_PARENT/rk3588-hdmi-audio-$(date '+%Y%m%d-%H%M%S')
	mkdir -p "$RESULT_ROOT"
	run_case "$2" "${3:-auto}" "${4:-auto}" "${5:-current}" "${6:-}"
	echo "results: $RESULT_ROOT"
	;;
baseline)
	[[ $# -eq 1 ]] || die "baseline takes no arguments"
	RESULT_ROOT=$RESULT_PARENT/rk3588-hdmi-audio-$(date '+%Y%m%d-%H%M%S')
	mkdir -p "$RESULT_ROOT"
	run_baseline
	echo "results: $RESULT_ROOT"
	;;
matrix)
	[[ $# -eq 1 ]] || die "matrix takes no arguments"
	RESULT_ROOT=$RESULT_PARENT/rk3588-hdmi-audio-$(date '+%Y%m%d-%H%M%S')
	mkdir -p "$RESULT_ROOT"
	run_matrix
	echo "results: $RESULT_ROOT"
	;;
esac
