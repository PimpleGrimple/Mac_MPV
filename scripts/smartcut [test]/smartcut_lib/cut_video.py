# =============================================================================
# cut_video.py — fixed version of the smartcut library's core cutter
#
# FIXES (applied to the upstream smartcut package from GitHub/PyPI):
#
#   FIX 1 — Wrong end frame (1 frame too early) on BD H.264 content
#   ---------------------------------------------------------------
#   Root cause: gop_start_times_pts_s[tail_gop] stores the *smallest* PTS in
#   the GOP (= open-GOP B-frame PTS = 104.099s in the tested file), while the
#   old code used the decoded IDR frame PTS (104.141s) as the rebase origin.
#   The 42 ms mismatch between the two bases shifted every tail frame one frame
#   early, so the selected end frame was never included in the output.
#   Fix: tail segments now always use s.start_time (= gop_start_times_pts_s,
#   packet-PTS basis) as the rebase origin, keeping both bases consistent.
#
#   FIX 2 — 1-frame gap / jump at the stream-copy → re-encode seam
#   ---------------------------------------------------------------
#   Root cause: open-GOP B-frames (displayed before the IDR, decoded after it)
#   belong to the tail GOP in DTS order, so they are excluded from the
#   stream-copy. The tail re-encode is supposed to include them (s.start_time
#   equals the B-frame's PTS), but without decoder priming the decoder has no
#   backward reference frame (it lives in the previous GOP) and silently drops
#   the B-frame, producing a visible 1-frame jump at the seam.
#   Fix: tail re-encode segments now prime the decoder from the previous GOP so
#   the open-GOP B-frame decodes correctly. Priming frames (frame_time <
#   s.start_time) are filtered out; the B-frame itself (frame_time ==
#   s.start_time) passes through and is re-encoded at the correct output PTS.
#
# HOW TO INSTALL:
#   Find where smartcut is installed:
#     python3 -c "import smartcut; print(smartcut.__file__)"
#   Replace cut_video.py in that package directory with this file:
#     cp cut_video_fixed.py $(python3 -c "import smartcut; import os; print(os.path.dirname(smartcut.__file__))")/cut_video.py
# =============================================================================

import heapq
import os
from collections.abc import Callable, Generator
from dataclasses import dataclass
from fractions import Fraction
from typing import Protocol, TypeAlias, cast

import av
import av.bitstream
import numpy as np
from av import VideoCodecContext, VideoStream
from av.codec.context import CodecContext
from av.container.input import InputContainer
from av.container.output import OutputContainer
from av.packet import Packet
from av.stream import Disposition
from av.video.frame import PictureType, VideoFrame

from smartcut.media_container import MediaContainer

__version__ = "1.7"
from smartcut.media_utils import VideoExportMode, VideoExportQuality, get_crf_for_quality
from smartcut.misc_data import AudioExportInfo, AudioExportSettings, CutSegment
from smartcut.nal_tools import get_h265_nal_unit_type, is_leading_picture_nal_type

class ProgressCallback(Protocol):
    """Protocol for progress callback objects."""
    def emit(self, value: int) -> None:
        """Emit progress update."""
        ...


class StreamGenerator(Protocol):
    """Protocol for stream generators that produce packets for output."""
    def segment(self, cut_segment: CutSegment) -> list[Packet]: ...
    def finish(self) -> list[Packet]: ...


StreamGeneratorFactory: TypeAlias = Callable[[OutputContainer], StreamGenerator]


class CancelObject:
    cancelled: bool = False

@dataclass
class FrameHeapItem:
    """Wrapper for frames in the heap, sorted by PTS"""
    pts: int | None
    frame: VideoFrame

    def __lt__(self, other: 'FrameHeapItem') -> bool:
        # Handle None PTS values by treating them as -1 (earliest)
        self_pts = self.pts if self.pts is not None else -1
        other_pts = other.pts if other.pts is not None else -1
        return self_pts < other_pts

def is_annexb(packet: Packet | bytes | None) -> bool:
        if packet is None:
            return False
        data = bytes(packet)
        return data[:3] == b'\0\0\x01' or data[:4] == b'\0\0\0\x01'

def copy_packet(p: Packet) -> Packet:
    # return p
    packet = Packet(bytes(p))
    packet.pts = p.pts
    packet.dts = p.dts
    packet.duration = p.duration
    # packet.pos = p.pos
    packet.time_base = p.time_base
    packet.stream = p.stream
    packet.is_keyframe = p.is_keyframe
    for side_data in p.iter_sidedata():
        packet.set_sidedata(side_data)
    # packet.is_discard = p.is_discard

    return packet

def make_adjusted_segment_times(positive_segments: list[tuple[Fraction, Fraction]], media_container: MediaContainer) -> list[tuple[Fraction, Fraction]]:
    adjusted_segment_times = []
    EPSILON = Fraction(1, 1_000_000)
    for (s, e) in positive_segments:
        if s <= EPSILON:
            s = -10
        if e >= media_container.duration - EPSILON:
            e = media_container.duration + 10
        adjusted_segment_times.append((s + media_container.start_time, e + media_container.start_time))
    return adjusted_segment_times

def make_cut_segments(media_container: MediaContainer,
        positive_segments: list[tuple[Fraction, Fraction]],
        keyframe_mode: bool = False
        ) -> list[CutSegment]:
    cut_segments = []
    if media_container.video_stream is None:
        first_audio_track = media_container.audio_tracks[0]
        min_time = first_audio_track.frame_times[0]
        max_time = first_audio_track.frame_times[-1] + Fraction(1,10000)
        for p in positive_segments:
            s = max(p[0], min_time)
            e = min(p[1], max_time)
            while s + 20 < e:
                cut_segments.append(CutSegment(False, s, s + 19))
                s += 19
            cut_segments.append(CutSegment(False, s, e))
        return cut_segments

    source_cutpoints = [*media_container.gop_start_times_pts_s, media_container.start_time + media_container.duration + Fraction(1,10000)]
    p = 0
    for gop_idx, (i, o, i_dts, o_dts) in enumerate(zip(source_cutpoints[:-1], source_cutpoints[1:], media_container.gop_start_times_dts, media_container.gop_end_times_dts)):
        while p < len(positive_segments) and positive_segments[p][1] <= i:
            p += 1

        # Three cases: no overlap, complete overlap, and partial overlap
        if p == len(positive_segments) or o <= positive_segments[p][0]:
            pass
        elif keyframe_mode or (i >= positive_segments[p][0] and o <= positive_segments[p][1]):
            cut_segments.append(CutSegment(False, i, o, i_dts, o_dts, gop_idx))
        else:
            if i > positive_segments[p][0]:
                cut_segments.append(CutSegment(True, i, positive_segments[p][1], i_dts, o_dts, gop_idx))
                p += 1
            while p < len(positive_segments) and positive_segments[p][1] < o:
                cut_segments.append(CutSegment(True, positive_segments[p][0], positive_segments[p][1], i_dts, o_dts, gop_idx))
                p += 1
            if p < len(positive_segments) and positive_segments[p][0] < o:
                cut_segments.append(CutSegment(True, positive_segments[p][0], o, i_dts, o_dts, gop_idx))

    return cut_segments

class PassthruAudioCutter:
    def __init__(self, media_container: MediaContainer, output_av_container: OutputContainer,
                track_index: int, export_settings: AudioExportSettings) -> None:
        self.track = media_container.audio_tracks[track_index]

        self.out_stream = output_av_container.add_stream_from_template(self.track.av_stream, options={'x265-params': 'log_level=error'})

        self.out_stream.metadata.update(self.track.av_stream.metadata)
        self.out_stream.disposition = cast(Disposition, self.track.av_stream.disposition.value)
        self.segment_start_in_output = 0
        self.prev_dts = -100_000
        self.prev_pts = -100_000

    def segment(self, cut_segment: CutSegment) -> list[Packet]:
        in_tb = cast(Fraction, self.track.av_stream.time_base)
        if cut_segment.start_time <= 0:
            start = 0
        else:
            start_pts = round(cut_segment.start_time / in_tb)
            start = np.searchsorted(self.track.frame_times_pts, start_pts)
        end_pts = round(cut_segment.end_time / in_tb)
        end = np.searchsorted(self.track.frame_times_pts, end_pts)
        in_packets = self.track.packets[start : end]
        packets = []
        for p in in_packets:
            if p.dts is None or p.pts is None:
                continue
            packet = copy_packet(p)
            # packet = p
            packet.stream = self.out_stream
            packet.pts = int(p.pts + (self.segment_start_in_output - cut_segment.start_time) / in_tb)
            packet.dts = int(p.dts + (self.segment_start_in_output - cut_segment.start_time) / in_tb)
            if packet.pts <= self.prev_pts:
                print("Correcting for too low pts in audio passthru")
                packet.pts = self.prev_pts + 1
            if packet.dts <= self.prev_dts:
                print("Correcting for too low dts in audio passthru")
                packet.dts = self.prev_dts + 1
            self.prev_pts = packet.pts
            self.prev_dts = packet.dts
            packets.append(packet)

        self.segment_start_in_output += cut_segment.end_time - cut_segment.start_time
        return packets

    def finish(self) -> list[Packet]:
        return []

class SubtitleCutter:
    def __init__(self, media_container: MediaContainer, output_av_container: OutputContainer, subtitle_track_index: int) -> None:
        self.track_i = subtitle_track_index
        self.packets = media_container.subtitle_tracks[subtitle_track_index]

        self.in_stream = media_container.av_container.streams.subtitles[subtitle_track_index]
        self.out_stream = output_av_container.add_stream_from_template(self.in_stream)
        self.out_stream.metadata.update(self.in_stream.metadata)
        self.out_stream.disposition = cast(Disposition, self.in_stream.disposition.value)
        self.segment_start_in_output = 0
        self.prev_pts = -100_000

        self.current_packet_i = 0

    def segment(self, cut_segment: CutSegment) -> list[Packet]:
        in_tb = cast(Fraction, self.in_stream.time_base)
        segment_start_pts = int(cut_segment.start_time / in_tb)
        segment_end_pts = int(cut_segment.end_time / in_tb)

        out_packets = []

        # TODO: This is the simplest implementation of subtitle cutting. Investigate more complex logic.
        # We include subtitles for the whole original time if the subtitle start time is included in the output
        # Good: simple, Bad: 1) if start is cut it's not shown at all 2) we can show a subtitle for too long if there is cut after it's shown
        while self.current_packet_i < len(self.packets):
            p = self.packets[self.current_packet_i]
            if p.pts < segment_start_pts:
                self.current_packet_i += 1
            elif p.pts >= segment_start_pts and p.pts < segment_end_pts:
                out_packets.append(p)
                self.current_packet_i += 1
            else:
                break

        segment_out_start = self.segment_start_in_output / in_tb
        segment_out_end = (self.segment_start_in_output + cut_segment.end_time - cut_segment.start_time) / in_tb

        for packet in out_packets:
            packet.stream = self.out_stream
            packet.pts = int(packet.pts - segment_start_pts + segment_out_start)

            if packet.pts < self.prev_pts:
                print("Correcting for too low pts in subtitle passthru. This should not happen.")
                packet.pts = self.prev_pts + 1
            packet.dts = packet.pts
            self.prev_pts = packet.pts
            self.prev_dts = packet.dts

            # Clamp subtitle duration so packets don't extend past the video cut end.
            # Without clamping, an ASS dialogue starting near the cut point with a long
            # duration (e.g. 4s) stretches the entire Matroska container duration,
            # leaving an empty tail where video/audio stop early and mpv skips.
            if packet.duration is not None and packet.duration > 0:
                max_dur = int(segment_out_end - packet.pts)
                if max_dur <= 0:
                    packet.duration = 0
                elif packet.duration > max_dur:
                    packet.duration = max_dur

        self.segment_start_in_output += cut_segment.end_time - cut_segment.start_time
        return out_packets

    def finish(self) -> list[Packet]:
        return []



@dataclass
class VideoSettings:
    mode: VideoExportMode
    quality: VideoExportQuality
    codec_override: str = 'copy'

class VideoCutter:
    def __init__(self, media_container: MediaContainer, output_av_container: OutputContainer, video_settings: VideoSettings, log_level: str | None) -> None:
        self.media_container = media_container
        self.log_level = log_level
        self.encoder_inited = False
        self.video_settings = video_settings

        self.enc_codec = None

        self.in_stream = cast(VideoStream, media_container.video_stream)
        # Assert time_base is not None once at initialization
        assert self.in_stream.time_base is not None, "Video stream must have a time_base"
        self.in_time_base: Fraction = self.in_stream.time_base

        # Open another container because seeking to beginning of the file is unreliable...
        self.input_av_container: InputContainer = av.open(media_container.path, 'r', metadata_errors='ignore')

        self.demux_iter = self.input_av_container.demux(self.in_stream)
        self.demux_saved_packet = None

        # Frame buffering for fetch_frame (using heap for efficient PTS ordering)
        self.frame_buffer = []
        self.frame_buffer_gop_dts = -1
        self.decoder = self.in_stream.codec_context

        if video_settings.mode == VideoExportMode.RECODE and video_settings.codec_override != 'copy':
            self.out_stream = cast(VideoStream, output_av_container.add_stream(video_settings.codec_override, rate=self.in_stream.guessed_rate, options={'x265-params': 'log_level=error'}))
            self.out_stream.width = self.in_stream.width
            self.out_stream.height = self.in_stream.height
            if self.in_stream.sample_aspect_ratio is not None:
                self.out_stream.sample_aspect_ratio = self.in_stream.sample_aspect_ratio
            self.out_stream.metadata.update(self.in_stream.metadata)
            self.out_stream.disposition = cast(Disposition, self.in_stream.disposition.value)
            self.out_stream.time_base = self.in_time_base
            self.codec_name = video_settings.codec_override

            self.init_encoder()
            self.enc_codec = self.out_stream.codec_context
            self.enc_codec.options.update(self.encoding_options)
            self.enc_codec.time_base = self.in_time_base
            self.enc_codec.thread_type = "FRAME"
            self.enc_last_pts = -1
        else:
            # Map codec name for decoder to encoder compatibility (AV1 case)
            original_codec_name = self.in_stream.codec_context.name

            codec_mapping = {
                'libdav1d': 'libsvtav1' if 'libsvtav1' in av.codecs_available else 'libaom-av1',  # AV1 decoder to encoder
                'av1': 'libsvtav1' if 'libsvtav1' in av.codecs_available else 'libaom-av1',
            }

            mapped_codec_name = codec_mapping.get(original_codec_name, original_codec_name)

            if mapped_codec_name != original_codec_name:
                # Need to create stream with mapped codec name. Can't use copy from template b/c codec name has changed
                rate = self.in_stream.guessed_rate or Fraction(60, 1)
                self.out_stream = cast(VideoStream, output_av_container.add_stream(mapped_codec_name, rate=rate))
                self.out_stream.width = self.in_stream.width
                self.out_stream.height = self.in_stream.height
                if self.in_stream.codec_context.pix_fmt is not None:
                    self.out_stream.pix_fmt = self.in_stream.codec_context.pix_fmt
                if self.in_stream.sample_aspect_ratio is not None:
                    self.out_stream.sample_aspect_ratio = self.in_stream.sample_aspect_ratio
                self.out_stream.metadata.update(self.in_stream.metadata)
                self.out_stream.disposition = cast(Disposition, self.in_stream.disposition.value)
                self.out_stream.time_base = self.in_stream.time_base
                if 'svtav1' in mapped_codec_name:
                    self.out_stream.codec_context.time_base = Fraction(1, rate)
                    self.out_stream.codec_context.framerate = rate
                    self.out_stream.codec_context.options = {'b': '0', 'preset': '7', 'tune': '0', 'crf': '18'}
                self.codec_name = mapped_codec_name
            else:
                # Copy the stream if no mapping needed
                self.out_stream = output_av_container.add_stream_from_template(self.in_stream, options={'x265-params': 'log_level=error'})
                self.out_stream.metadata.update(self.in_stream.metadata)
                self.out_stream.disposition = cast(Disposition, self.in_stream.disposition.value)
                self.out_stream.time_base = self.in_stream.time_base
                self.codec_name = original_codec_name


            # if self.codec_name == 'mpeg2video':
                # self.out_stream.average_rate = self.in_stream.average_rate
                # self.out_stream.base_rate = self.in_stream.base_rate

            self.remux_bitstream_filter = av.bitstream.BitStreamFilterContext('null', self.in_stream, self.out_stream)
            if self.in_stream.codec_context.name == 'h264' and not is_annexb(self.in_stream.codec_context.extradata):
                self.remux_bitstream_filter = av.bitstream.BitStreamFilterContext('h264_mp4toannexb', self.in_stream, self.out_stream)
            elif self.in_stream.codec_context.name == 'hevc' and not is_annexb(self.in_stream.codec_context.extradata):
                self.remux_bitstream_filter = av.bitstream.BitStreamFilterContext('hevc_mp4toannexb', self.in_stream, self.out_stream)
            # MPEG-4 Visual family: optional filters for robustness (ASF/AVI tend to need this)
            elif self.in_stream.codec_context.name in {'mpeg4', 'msmpeg4v3', 'msmpeg4v2', 'msmpeg4v1'}:
                self.remux_bitstream_filter = av.bitstream.BitStreamFilterContext('dump_extra', self.in_stream, self.out_stream)

            if 'svtav1' in self.codec_name:
                rate = self.in_stream.guessed_rate or Fraction(60, 1)
                self.out_stream.codec_context.time_base = Fraction(1, rate)
                self.out_stream.codec_context.framerate = rate
                level_str = '6.1' if (self.in_stream.height or 0) > 2160 else '5.1'
                self.out_stream.codec_context.options.update({
                    'b': '0',
                    'preset': '7',
                    'tune': '0',
                    'crf': '18',
                    'level': level_str
                })

        self._normalize_output_codec_tag(output_av_container)

        # Assert out_stream time_base is not None once at initialization
        assert self.out_stream.time_base is not None, "Output stream must have a time_base"
        self.out_time_base: Fraction = self.out_stream.time_base

        self.last_dts = -100_000_000

        self.segment_start_in_output = 0

        # Track stream continuity for CRA to BLA conversion
        self.last_remuxed_segment_gop_index = None
        self.is_first_remuxed_segment = True
        # Track decoder continuity between GOPs: last GOP end DTS consumed
        self._last_fetch_end_dts: int | None = None

    def _normalize_output_codec_tag(self, output_av_container: OutputContainer) -> None:
        """Ensure codec tags are compatible with output container format."""

        container_name = output_av_container.format.name.lower() if output_av_container.format.name else ''
        out_codec_ctx = cast(CodecContext, self.out_stream.codec_context)
        # Use input codec name since output codec_context.name may be encoder name (e.g., 'libx265')
        in_codec_name = self.in_stream.codec_context.name

        is_mp4_mov_mkv = any(name in container_name for name in ('mp4', 'mov', 'matroska', 'webm'))
        is_mp4_or_mov = any(name in container_name for name in ('mp4', 'mov'))

        # Normalize MPEG-TS codec tags for MP4/MOV/MKV containers
        if is_mp4_mov_mkv and in_codec_name == 'h264' and self._is_mpegts_h264_tag(out_codec_ctx.codec_tag):
            out_codec_ctx.codec_tag = 'avc1'

        # For HEVC in MP4/MOV: use hev1 to keep VPS/SPS/PPS inline in the bitstream.
        # hvc1 strips parameter sets to extradata, but smartcut's x265-encoded segments
        # need their own VPS/SPS/PPS inline (via repeat-headers=1) since they differ from
        # the source encoder's. hev1 allows both extradata and inline parameter sets.
        if is_mp4_or_mov and in_codec_name in ('hevc', 'h265'):
            out_codec_ctx.codec_tag = 'hev1'
        elif is_mp4_mov_mkv and in_codec_name in ('hevc', 'h265') and self._is_mpegts_hevc_tag(out_codec_ctx.codec_tag):
            out_codec_ctx.codec_tag = 'hvc1'

    @staticmethod
    def _is_mpegts_h264_tag(codec_tag: str) -> bool:
        """Check if codec tag is MPEG-TS style H.264 tag."""
        return codec_tag == '\x1b\x00\x00\x00'

    @staticmethod
    def _is_mpegts_hevc_tag(codec_tag: str) -> bool:
        """Check if codec tag is MPEG-TS style HEVC tag."""
        return codec_tag in ('HEVC', '\x24\x00\x00\x00')

    def init_encoder(self) -> None:
        self.encoder_inited = True
        # v_codec = self.in_stream.codec_context
        profile = self.out_stream.codec_context.profile

        codec_name = self.codec_name or ''
        if 'av1' in codec_name:
            if 'svtav1' in codec_name:
                self.codec_name = 'libsvtav1'
            elif 'aom' in codec_name:
                self.codec_name = 'libaom-av1'
            else:
                self.codec_name = 'libsvtav1' if 'libsvtav1' in av.codecs_available else 'libaom-av1'
            profile = None
        if self.codec_name == 'vp9':
            if profile is not None:
                profile = profile[-1:]
                if int(profile) > 1:
                    raise ValueError("VP9 Profile 2 and Profile 3 are not supported by the encoder. Please select cutting on keyframes mode.")
        elif profile is not None:
            if 'Baseline' in profile:
                profile = 'baseline'
            elif 'High 4:4:4' in profile:
                profile = 'high444'
            elif 'Rext' in profile or 'Simple' in profile: # This is some sort of h265 extension. This might be the source of some issues I've had?
                profile = None
            else:
                profile = profile.lower().replace(':', '').replace(' ', '')

        # Get CRF value for quality setting
        crf_value = get_crf_for_quality(self.video_settings.quality)

        # Adjust CRF for newer codecs that are more efficient
        if any(c in self.codec_name for c in ['hevc', 'av1', 'vp9', 'svtav1']):
            crf_value += 4
        if self.video_settings.quality == VideoExportQuality.LOSSLESS:
            crf_value = 0

        self.encoding_options = {'crf': str(crf_value)}
        if 'svtav1' in self.codec_name:
            self.encoding_options['b'] = '0'
            self.encoding_options['preset'] = '7'
            self.encoding_options['tune'] = '0'
        elif 'aom' in self.codec_name:
            self.encoding_options['cpu-used'] = '6'
            self.encoding_options['row-mt'] = '1'
        if self.codec_name == 'vp9' and self.video_settings.quality == VideoExportQuality.LOSSLESS:
            self.encoding_options['lossless'] = '1'
        # encoding_options = {}
        if profile is not None:
            self.encoding_options['profile'] = profile

        if self.codec_name == 'h264':
            # sps-id = 3. We try to avoid collisions with the existing SPS ids.
            # Particularly 0 is very commonly used. Technically we should probably try
            # to dynamically set this to a safe number, but it can be difficult to know
            # our detection is robust / correct.
            self.encoding_options['x264-params'] = 'sps-id=3'

        elif self.codec_name == 'hevc':
            # FIX: Do NOT blindly copy x265 params from the source's extradata.
            # The extradata was written by the ORIGINAL encoder, which may have run on a
            # different OS (e.g. Windows x265 3.5) with platform-specific params like
            # cpuid=, numa-pools=, total-frames=, frame-threads=, etc. Passing those to
            # a different x265 version (e.g. 4.x on macOS) causes x265_encoder_open()
            # to return NULL and AVERROR_INVALIDDATA. The upstream approach only works
            # when source and re-encoder are the same x265 build on the same platform.
            #
            # Instead: derive only the bit depth from the pixel format (critical for
            # 10/12-bit sources) and let x265 use its own defaults for everything else.
            # FFmpeg's libx265 wrapper already sets internalBitDepth from pix_fmt, but
            # passing it explicitly via x265-params is more reliable across versions.

            assert self.in_stream is not None
            assert self.in_stream.codec_context is not None

            x265_params = []

            # Derive bit depth from pixel format — the ONLY param we must carry over.
            pix_fmt = str(self.in_stream.codec_context.pix_fmt or '')
            if '10' in pix_fmt:
                x265_params.append('bitdepth=10')
            elif '12' in pix_fmt:
                x265_params.append('bitdepth=12')
            # 8-bit: no param needed (x265 default)

            # Repeat headers. This should be the same as `global_headers = False`,
            # but for some reason setting this explicitly is necessary with x265.
            x265_params.append('repeat-headers=1')

            # Disable encoder info SEI. Since smartcut only re-encodes frames at cut points,
            # having x265 write its encoding settings would be misleading - it doesn't
            # represent the original video's settings.
            x265_params.append('info=0')

            if self.log_level is not None:
                x265_params.append(f'log_level={self.log_level}')

            if self.video_settings.quality == VideoExportQuality.LOSSLESS:
                x265_params.append('lossless=1')

            self.encoding_options['x265-params'] = ':'.join(x265_params)


    def _fix_packet_timestamps(self, packet: Packet) -> None:
        """Fix packet DTS/PTS to ensure monotonic increase and PTS >= DTS."""
        packet.stream = self.out_stream
        packet.time_base = self.out_time_base

        # Treat garbage DTS values as None (can occur during encoder flush due to PyAV
        # reading uninitialized memory when frame is None during flush)
        # See: https://github.com/PyAV-Org/PyAV/issues/397
        #      https://github.com/PyAV-Org/PyAV/discussions/933
        if packet.dts is not None and (packet.dts < -900_000 or packet.dts > 1_000_000_000_000):
            packet.dts = None

        if packet.dts is not None:
            if packet.dts <= self.last_dts:
                packet.dts = self.last_dts + 1
            # Ensure PTS >= DTS (required by all container formats)
            # This check is separate from the monotonicity check above because
            # remux_segment may produce packets with DTS > PTS when adjusting
            # for B-frame delays after an encoded segment.
            if packet.pts is not None and packet.pts < packet.dts:
                packet.pts = packet.dts
            self.last_dts = packet.dts
        if packet.dts is None:
            # When DTS is None, use PTS as fallback (common for keyframes without B-frame reordering)
            # Ensure we don't use the sentinel value to avoid extremely negative DTS
            pts_value = packet.pts if packet.pts is not None else 0
            if self.last_dts < 0:
                # First packet with None DTS, use PTS
                packet.dts = pts_value
            else:
                # Subsequent packets, ensure monotonic increase
                # Don't jump DTS up to match PTS - just increment minimally to preserve PTS >= DTS
                packet.dts = self.last_dts + 1
            self.last_dts = packet.dts

    def _ensure_enc_codec(self) -> None:
        """Initialize enc_codec if not already set."""
        if self.enc_codec is not None:
            return

        muxing_codec = self.out_stream.codec_context
        enc_codec = cast(VideoCodecContext, CodecContext.create(self.codec_name, 'w'))

        rate = muxing_codec.rate or self.in_stream.guessed_rate
        if rate is not None:
            enc_codec.rate = rate
        if 'svtav1' in self.codec_name:
            enc_codec.framerate = rate or Fraction(60, 1)
            level_str = '6.1' if (self.in_stream.height or 0) > 2160 else '5.1'
            enc_codec.options.update({'level': level_str})
        enc_codec.options.update(self.encoding_options)

        # Leaving this here for future consideration: manually setting the bframe count seems to make sense in principle.
        # But atleast in the test suite, it seemed to cause more issues that in solves.
        # metadata_b_frames = max(self.in_stream.codec_context.max_b_frames, 1 if self.in_stream.codec_context.has_b_frames else 0)
        # enc_codec.max_b_frames = metadata_b_frames

        enc_codec.width = muxing_codec.width
        enc_codec.height = muxing_codec.height
        enc_codec.pix_fmt = muxing_codec.pix_fmt

        if muxing_codec.sample_aspect_ratio is not None:
            enc_codec.sample_aspect_ratio = muxing_codec.sample_aspect_ratio
        if self.codec_name == 'mpeg2video':
            enc_codec.time_base = Fraction(1, muxing_codec.rate)
        else:
            enc_codec.time_base = self.out_time_base

        if 'svtav1' in self.codec_name:
            enc_codec.bit_rate = 0
        elif muxing_codec.bit_rate is not None:
            enc_codec.bit_rate = muxing_codec.bit_rate
        if muxing_codec.bit_rate_tolerance is not None:
            enc_codec.bit_rate_tolerance = muxing_codec.bit_rate_tolerance
        enc_codec.codec_tag = muxing_codec.codec_tag
        enc_codec.thread_type = "FRAME"
        self.enc_last_pts = -1
        self.enc_codec = enc_codec

    def segment(self, cut_segment: CutSegment) -> list[Packet]:
        if cut_segment.require_recode:
            packets = self.recode_segment(cut_segment)
        elif self._should_hybrid_recode_cra(cut_segment):
            # CRA GOP with leading pictures: recode leading pics, remux rest
            # Don't flush encoder - leading frames continue into existing encoder
            packets = self.hybrid_recode_cra_segment(cut_segment)
            # Update tracking variables (same as remux path)
            self.last_remuxed_segment_gop_index = cut_segment.gop_index
            self.is_first_remuxed_segment = False
        else:
            packets = self.flush_encoder()
            packets.extend(self.remux_segment(cut_segment))
            # Update tracking variables for CRA to BLA conversion
            self.last_remuxed_segment_gop_index = cut_segment.gop_index
            self.is_first_remuxed_segment = False

        self.segment_start_in_output += cut_segment.end_time - cut_segment.start_time

        for packet in packets:
            self._fix_packet_timestamps(packet)

        return packets

    def finish(self) -> list[Packet]:
        packets = self.flush_encoder()
        for packet in packets:
            self._fix_packet_timestamps(packet)

        self.input_av_container.close()

        return packets

    def recode_segment(self, s: CutSegment) -> list[Packet]:
        if not self.encoder_inited:
            self.init_encoder()
        result_packets = []

        self._ensure_enc_codec()
        assert self.enc_codec is not None

        # Detect TAIL segment: start_time aligns with the GOP's smallest PTS (gop_start_times_pts_s
        # stores min-PTS of the GOP, which for open-GOP streams equals the open-GOP B-frame's PTS,
        # not the IDR's PTS). Must be computed before setting decoder_priming_dts.
        gop_start_time = self.media_container.gop_start_times_pts_s[s.gop_index]
        is_tail = abs(float(s.start_time - gop_start_time)) < 0.002
        tail_rebase_origin: Fraction | None = None

        # Prime decoder from previous GOP in two cases:
        #  1. RASL/CRA: HEVC frames that need previous GOP for reference decoding.
        #  2. TAIL segment with gop_index > 0: open-GOP B-frames (decoded after the IDR in DTS
        #     order but displayed before it) have their backward reference in the previous GOP.
        #     Without priming those frames decode corrupted / are silently dropped.
        decoder_priming_dts = None
        if s.gop_index > 0:
            if (
                s.gop_index < len(self.media_container.gop_has_rasl)
                and self.media_container.gop_has_rasl[s.gop_index]
            ):
                decoder_priming_dts = self.media_container.gop_start_times_dts[s.gop_index - 1]
            elif is_tail:
                # Prime so the open-GOP B-frames at the start of the tail GOP can be decoded.
                decoder_priming_dts = self.media_container.gop_start_times_dts[s.gop_index - 1]

        for frame in self.fetch_frame(s.gop_start_dts, s.gop_end_dts, s.end_time, decoder_priming_dts):
            assert frame.pts is not None, "Frame pts should not be None after decoding"
            in_tb = frame.time_base if frame.time_base is not None else self.in_time_base
            frame_time = frame.pts * in_tb

            if is_tail:
                # Skip frames from the primed previous GOP (frame_time < s.start_time).
                # The open-GOP B-frame itself has frame_time == s.start_time, so it passes.
                if frame_time < s.start_time:
                    continue
                # All tail frames rebase relative to s.start_time (packet-PTS basis), which
                # is consistent with how segment_start_in_output was accumulated.
                if tail_rebase_origin is None:
                    tail_rebase_origin = s.start_time
            else:
                # HEAD: skip frames that precede the user's mark A.
                if frame_time < s.start_time:
                    continue

            if frame_time >= s.end_time:
                break

            out_tb = self.out_time_base if self.codec_name != 'mpeg2video' else self.enc_codec.time_base
            rebase_origin = tail_rebase_origin if (is_tail and tail_rebase_origin is not None) else s.start_time

            frame.pts = int(frame.pts - rebase_origin / in_tb)

            frame.pts = int(frame.pts * in_tb / out_tb)
            frame.time_base = out_tb
            frame.pts = int(frame.pts + self.segment_start_in_output / out_tb)

            if frame.pts <= self.enc_last_pts:
                frame.pts = int(self.enc_last_pts + 1)
            self.enc_last_pts = frame.pts

            frame.pict_type = PictureType.NONE
            result_packets.extend(self.enc_codec.encode(frame))

        if self.codec_name == 'mpeg2video':
            for p in result_packets:
                p.pts = p.pts * p.time_base / self.out_time_base
                p.dts = p.dts * p.time_base / self.out_time_base
                p.time_base = self.out_time_base
        return result_packets

    def remux_segment(self, s: CutSegment) -> list[Packet]:
        result_packets = []
        segment_start_pts = int(s.start_time / self.in_time_base)

        for packet in self.fetch_packet(s.gop_start_dts, s.gop_end_dts):
            # Apply timing adjustments
            segment_start_offset = self.segment_start_in_output / self.out_time_base
            pts = packet.pts if packet.pts else 0
            packet.pts = int((pts - segment_start_pts) * self.in_time_base / self.out_time_base + segment_start_offset)
            if packet.dts is not None:
                packet.dts = int((packet.dts - segment_start_pts) * self.in_time_base / self.out_time_base + segment_start_offset)

            result_packets.extend(self.remux_bitstream_filter.filter(packet))

        result_packets.extend(self.remux_bitstream_filter.filter(None))

        self.remux_bitstream_filter.flush()
        return result_packets

    def _should_hybrid_recode_cra(self, s: CutSegment) -> bool:
        """
        Check if this segment should use hybrid recode (recode leading pictures only).
        This is needed when:
        1. GOP has RASL frames (they reference frames before the CRA)
        2. There's discontinuity before this point (content was skipped/cut)
        """
        # Check 1: GOP must have RASL frames
        if s.gop_index < 0 or s.gop_index >= len(self.media_container.gop_has_rasl):
            return False
        if not self.media_container.gop_has_rasl[s.gop_index]:
            return False

        # Check 2: Must have discontinuity before this point
        has_discontinuity = (
            (self.is_first_remuxed_segment and s.gop_index > 0) or
            (self.last_remuxed_segment_gop_index is not None and s.gop_index > self.last_remuxed_segment_gop_index + 1)
        )
        return has_discontinuity

    def hybrid_recode_cra_segment(self, s: CutSegment) -> list[Packet]:
        """
        Hybrid recode for CRA GOPs: recode only leading pictures (RASL/RADL),
        remux CRA + trailing pictures unchanged.
        """
        if not self.encoder_inited:
            self.init_encoder()

        result_packets: list[Packet] = []

        # Same reference point as remux_segment
        segment_start_pts = int(s.start_time / self.in_time_base)
        segment_start_offset = self.segment_start_in_output / self.out_time_base

        # Get leading boundary
        leading_end_dts = self.media_container.gop_leading_end_dts[s.gop_index]
        assert leading_end_dts is not None, "hybrid_recode_cra_segment called without leading pictures"

        self._ensure_enc_codec()
        assert self.enc_codec is not None

        # Decoder priming for RASL reference frames
        decoder_priming_dts = None
        if s.gop_index > 0:
            decoder_priming_dts = self.media_container.gop_start_times_dts[s.gop_index - 1]

        # Decode leading + CRA frames, collect packets for later remux
        collected_packets: list[Packet] = []
        all_frames: list[VideoFrame] = []

        for frame in self.fetch_frame(s.gop_start_dts, leading_end_dts, s.end_time,
                                       decoder_priming_dts, collected_packets):
            if frame.pts is not None:
                all_frames.append(frame)

        # Get CRA PTS (collected_packets has only non-leading packets, i.e., just CRA)
        assert len(collected_packets) > 0, "No CRA packet found in GOP"
        cra_pts = collected_packets[0].pts
        assert cra_pts is not None, "CRA packet has no PTS"

        # Get GOP start time to filter out priming frames from previous GOPs
        gop_start_time = self.media_container.gop_start_times_pts_s[s.gop_index]

        # Leading frames: PTS >= GOP start AND PTS < CRA PTS (will be encoded)
        # Filter by GOP start to exclude priming frames from previous GOPs
        leading_frames = [
            f for f in all_frames
            if f.pts is not None
            and f.pts * (f.time_base if f.time_base is not None else self.in_time_base) >= gop_start_time
            and f.pts < cra_pts
        ]
        leading_frames.sort(key=lambda f: f.pts if f.pts is not None else 0)

        # Encode leading frames with same timing formula as remux_segment
        for frame in leading_frames:
            assert frame.pts is not None
            # Same formula as remux_segment
            frame.pts = int((frame.pts - segment_start_pts) * self.in_time_base / self.out_time_base + segment_start_offset)
            frame.time_base = self.out_time_base

            if frame.pts <= self.enc_last_pts:
                frame.pts = int(self.enc_last_pts + 1)
            self.enc_last_pts = frame.pts

            frame.pict_type = PictureType.NONE
            result_packets.extend(self.enc_codec.encode(frame))

        result_packets.extend(self.flush_encoder())

        # Fix encoder DTS
        for p in result_packets:
            if p.dts is None or p.dts > 1_000_000_000_000:
                p.dts = p.pts

        # Remux: collected packets (CRA, leading already filtered in fetch_frame) + trailing
        # Handle in one loop with same timing as remux_segment
        remux_packets = list(collected_packets)
        remux_packets.extend(self.fetch_packet(leading_end_dts, s.gop_end_dts))

        for packet in remux_packets:
            pts = packet.pts if packet.pts else 0
            packet.pts = int((pts - segment_start_pts) * self.in_time_base / self.out_time_base + segment_start_offset)
            if packet.dts is not None:
                packet.dts = int((packet.dts - segment_start_pts) * self.in_time_base / self.out_time_base + segment_start_offset)
            result_packets.extend(self.remux_bitstream_filter.filter(packet))

        result_packets.extend(self.remux_bitstream_filter.filter(None))
        self.remux_bitstream_filter.flush()

        return result_packets

    def flush_encoder(self) -> list[Packet]:
        if self.enc_codec is None:
            return []

        result_packets = self.enc_codec.encode()

        if self.codec_name == 'mpeg2video':
            for p in result_packets:
                if p.time_base is not None:
                    if p.pts is not None:
                        p.pts = int(p.pts * p.time_base / self.out_time_base)
                    if p.dts is not None:
                        p.dts = int(p.dts * p.time_base / self.out_time_base)
                p.time_base = self.out_time_base

        self.enc_codec = None
        return result_packets

    def fetch_packet(self, target_dts: int, end_dts: int) -> Generator[Packet, None, None]:
        # First, check if we have a saved packet from previous call
        if self.demux_saved_packet is not None:
            saved_dts = self.demux_saved_packet.dts if self.demux_saved_packet.dts is not None else -100_000_000
            if saved_dts >= target_dts:
                if saved_dts <= end_dts:
                    packet = self.demux_saved_packet
                    self.demux_saved_packet = None
                    yield packet
                else:
                    # Saved packet is beyond our end range, don't yield it
                    return
            else:
                # Saved packet is before our target, clear it
                self.demux_saved_packet = None

        for packet in self.demux_iter:
            in_dts = packet.dts if packet.dts is not None else -100_000_000

            # Skip packets before target_dts
            if packet.pts is None or in_dts < target_dts:
                diff = (target_dts - in_dts) * self.in_time_base
                if in_dts > 0 and diff > 120:
                    t = int(target_dts - 30 / self.in_time_base)
                    # print(f"Seeking to skip a gap: {float(t * tb)}")
                    self.input_av_container.seek(t, stream = self.in_stream)
                    # Clear saved packet after seek since iterator position changed
                    self.demux_saved_packet = None
                continue

            # Check if packet exceeds end_dts
            if in_dts > end_dts:
                # Save this packet for next call and stop iteration
                self.demux_saved_packet = packet
                return

            # Packet is in our target range, yield it
            yield packet

    def fetch_frame(self, gop_start_dts: int, gop_end_dts: int, end_time: Fraction, decoder_priming_dts: int | None = None, collect_packets: list[Packet] | None = None) -> Generator[VideoFrame, None, None]:
        # Check if previous iteration consumed exactly to this GOP start
        continuous = self._last_fetch_end_dts is not None and (self._last_fetch_end_dts in (gop_end_dts, gop_start_dts))
        self._last_fetch_end_dts = gop_end_dts

        # Choose actual start DTS. Allow priming from previous GOP unless we're either still in the same GOP or continuing to the next one.
        start_dts = gop_start_dts if continuous else (decoder_priming_dts if decoder_priming_dts is not None else gop_start_dts)

        # Initialize or reset for new GOP boundary unless continuous
        if self.frame_buffer_gop_dts != gop_start_dts and not continuous:
            self.frame_buffer = []
            self.frame_buffer_gop_dts = gop_start_dts
            self.decoder.flush_buffers()

        # If asked to start earlier than GOP, seek and clear state (skip if continuous)
        if start_dts < gop_start_dts and not continuous:
            try:
                self.decoder.flush_buffers()
                self.frame_buffer = []
                self.input_av_container.seek(start_dts, stream=self.in_stream)
                self.demux_saved_packet = None
              # Recreate demux iterator after an explicit seek to ensure position is honored
                self.demux_iter = self.input_av_container.demux(self.in_stream)

            except Exception:
                pass

        # Process packets and yield frames when safe
        current_dts = gop_start_dts

        for packet in self.fetch_packet(start_dts, gop_end_dts):
            current_dts = packet.dts if packet.dts is not None else current_dts

            # Collect packets for remuxing if requested (hybrid recode path)
            # Skip: priming packets (dts < gop_start_dts), leading pictures (RASL/RADL)
            if collect_packets is not None:
                packet_dts = packet.dts if packet.dts is not None else current_dts
                should_collect = packet_dts >= gop_start_dts  # Skip priming packets
                if should_collect and self.codec_name == 'hevc':
                    nal_type = get_h265_nal_unit_type(bytes(packet))
                    if is_leading_picture_nal_type(nal_type):
                        should_collect = False
                if should_collect:
                    collect_packets.append(copy_packet(packet))

            # Decode packet and add frames to buffer
            for frame in self.decoder.decode(packet):
                heap_item = FrameHeapItem(frame.pts, frame)
                heapq.heappush(self.frame_buffer, heap_item)

            # Release frames that are safe (buffer_lowest_pts <= current_dts)
            BUFFERED_FRAMES_COUNT = 15 # We need this to be quite high, b/c GENPTS is on and we can't know if the pts values are real or fake
            while len(self.frame_buffer) > BUFFERED_FRAMES_COUNT:
                lowest_heap_item = self.frame_buffer[0]  # Peek at heap minimum
                frame = lowest_heap_item.frame
                frame_pts = lowest_heap_item.pts if lowest_heap_item.pts is not None else -1
                frame_time_base = frame.time_base if frame.time_base is not None else self.in_time_base

                # Only process frames that are safe to release (frame_pts <= current_dts)
                if frame_pts <= current_dts:
                    if frame_pts * frame_time_base < end_time:
                        heapq.heappop(self.frame_buffer)  # Remove from heap
                        yield frame
                    else:
                        # Safe frame is beyond end_time - we're done since all frames from now would be beyond end time
                        return
                else:
                    break

        # Final flush of the decoder
        try:
            for frame in self.decoder.decode(None):
                heap_item = FrameHeapItem(frame.pts, frame)
                heapq.heappush(self.frame_buffer, heap_item)
        except Exception:
            pass

        # Yield remaining frames within time range
        while self.frame_buffer:
            # Peek at the next frame without popping it
            next_frame = self.frame_buffer[0]
            frame = next_frame.frame
            frame_time_base = frame.time_base if frame.time_base is not None else self.in_time_base

            if (next_frame.pts is not None and
                next_frame.pts * frame_time_base < end_time):
                # Frame is within time range, pop and yield it
                heapq.heappop(self.frame_buffer)
                yield frame
            else:
                # Frame is outside time range, stop processing (leave it in buffer)
                break

def smart_cut(media_container: MediaContainer, positive_segments: list[tuple[Fraction, Fraction]],
              out_path: str, audio_export_info: AudioExportInfo | None = None, log_level: str | None = None, progress: ProgressCallback | None = None,
              video_settings: VideoSettings | None = None, segment_mode: bool = False, cancel_object: CancelObject | None = None,
              external_generator_factories: list[StreamGeneratorFactory] | None = None) -> Exception | None:
    if video_settings is None:
        video_settings = VideoSettings(VideoExportMode.SMARTCUT, VideoExportQuality.NORMAL)

    adjusted_segment_times = make_adjusted_segment_times(positive_segments, media_container)
    cut_segments = make_cut_segments(media_container, adjusted_segment_times, video_settings.mode == VideoExportMode.KEYFRAMES)

    if video_settings.mode == VideoExportMode.RECODE:
        for c in cut_segments:
            c.require_recode = True

    if segment_mode:
        output_files = []
        padding = len(str(len(adjusted_segment_times)))
        for i, s in enumerate(adjusted_segment_times):
            segment_index = str(i + 1).zfill(padding)  # Zero-pad the segment index
            if "#" in out_path:
                pound_index = out_path.rfind("#")
                output_file = out_path[:pound_index] + segment_index + out_path[pound_index + 1:]
            else:
                # Insert the segment index right before the last '.'
                dot_index = out_path.rfind(".")
                output_file = out_path[:dot_index] + segment_index + out_path[dot_index:] if dot_index != -1 else f"{out_path}{segment_index}"

            output_files.append((output_file, s))

    else:
        output_files = [(out_path, adjusted_segment_times[-1])]
    previously_done_segments = 0
    for output_path_segment in output_files:
        if cancel_object is not None and cancel_object.cancelled:
            break
        with av.open(output_path_segment[0], 'w') as output_av_container:
            output_av_container.metadata['ENCODED_BY'] = f'smartcut {__version__}'

            include_video = True
            if output_av_container.format.name in ['ogg', 'mp3', 'm4a', 'ipod', 'flac', 'wav']: #ipod is the real name for m4a, I guess
                include_video = False

                        # Preserve container attachments (e.g., MKV attachments) when supported by the output format
            container_name = (output_av_container.format.name or "").lower()
            supports_attachments = any(x in container_name for x in ("matroska", "webm"))

            if supports_attachments:
                # Copy attachment streams from the primary input container
                for in_stream in media_container.av_container.streams:
                    if getattr(in_stream, "type", None) != "attachment":
                        continue

                    output_av_container.add_stream_from_template(in_stream)

            generators = []
            if media_container.video_stream is not None and include_video:
                generators.append(VideoCutter(media_container, output_av_container, video_settings, log_level))

            if audio_export_info is not None:
                for track_i, track_export_settings in enumerate(audio_export_info.output_tracks):
                    if track_export_settings is not None and  track_export_settings.codec == 'passthru':
                        generators.append(PassthruAudioCutter(media_container, output_av_container, track_i, track_export_settings))

            for sub_track_i in range(len(media_container.subtitle_tracks)):
                generators.append(SubtitleCutter(media_container, output_av_container, sub_track_i))

            if external_generator_factories:
                for factory in external_generator_factories:
                    generators.append(factory(output_av_container))

            output_av_container.start_encoding()
            if progress is not None:
                progress.emit(len(cut_segments))
            for s in cut_segments[previously_done_segments:]:
                if cancel_object is not None and cancel_object.cancelled:
                    break
                if s.start_time >= output_path_segment[1][1]: # Go to the next output file
                    break

                if progress is not None:
                    progress.emit(previously_done_segments)
                previously_done_segments += 1
                assert s.start_time < s.end_time, f"Invalid segment: start_time {s.start_time} >= end_time {s.end_time}"
                for g in generators:
                    for packet in g.segment(s):
                        if packet.dts is not None and packet.dts < -900_000:
                            packet.dts = None
                        if packet.dts is not None and packet.dts > 1_000_000_000_000:
                            print(f"BAD DTS: seg {s.start_time:.3f}-{s.end_time:.3f} gop={s.gop_index} recode={s.require_recode} pts={packet.pts} dts={packet.dts}")
                        output_av_container.mux(packet)
            for g in generators:
                for packet in g.finish():
                    if packet.dts is not None and packet.dts > 1_000_000_000_000:
                        print(f"BAD DTS in finish: pts={packet.pts} dts={packet.dts}", flush=True)
                    output_av_container.mux(packet)
            if progress is not None:
                progress.emit(previously_done_segments)

        if cancel_object is not None and cancel_object.cancelled:
            last_file_path = output_path_segment[0]

            if os.path.exists(last_file_path):
                os.remove(last_file_path)
