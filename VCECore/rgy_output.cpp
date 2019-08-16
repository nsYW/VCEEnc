﻿// -----------------------------------------------------------------------------------------
// QSVEnc/NVEnc by rigaya
// -----------------------------------------------------------------------------------------
// The MIT License
//
// Copyright (c) 2011-2016 rigaya
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// ------------------------------------------------------------------------------------------

#include "rgy_output.h"
#include "rgy_bitstream.h"

#define WRITE_CHECK(writtenBytes, expected) { \
    if (writtenBytes != expected) { \
        AddMessage(RGY_LOG_ERROR, _T("Error writing file.\nNot enough disk space!\n")); \
        return RGY_ERR_UNDEFINED_BEHAVIOR; \
    } }

RGYOutput::RGYOutput() :
    m_encSatusInfo(),
    m_fDest(),
    m_outputIsStdout(false),
    m_inited(false),
    m_noOutput(false),
    m_OutType(OUT_TYPE_BITSTREAM),
    m_sourceHWMem(false),
    m_y4mHeaderWritten(false),
    m_strWriterName(),
    m_strOutputInfo(),
    m_VideoOutputInfo(),
    m_printMes(),
    m_outputBuffer(),
    m_readBuffer(),
    m_UVBuffer() {
    memset(&m_VideoOutputInfo, 0, sizeof(m_VideoOutputInfo));
}

RGYOutput::~RGYOutput() {
    m_encSatusInfo.reset();
    m_printMes.reset();
    Close();
}

void RGYOutput::Close() {
    AddMessage(RGY_LOG_DEBUG, _T("Closing...\n"));
    if (m_fDest) {
        m_fDest.reset();
        AddMessage(RGY_LOG_DEBUG, _T("Closed file pointer.\n"));
    }
    m_encSatusInfo.reset();
    m_outputBuffer.reset();
    m_readBuffer.reset();
    m_UVBuffer.reset();

    m_noOutput = false;
    m_inited = false;
    m_sourceHWMem = false;
    m_y4mHeaderWritten = false;
    AddMessage(RGY_LOG_DEBUG, _T("Closed.\n"));
    m_printMes.reset();
}

RGYOutputRaw::RGYOutputRaw() :
    m_seiNal()
#if ENABLE_AVSW_READER
    , m_pBsfc()
#endif //#if ENABLE_AVSW_READER
{
    m_strWriterName = _T("bitstream");
    m_OutType = OUT_TYPE_BITSTREAM;
}

RGYOutputRaw::~RGYOutputRaw() {
#if ENABLE_AVSW_READER
    m_pBsfc.reset();
#endif //#if ENABLE_AVSW_READER
}

#pragma warning (push)
#pragma warning (disable: 4127) //warning C4127: 条件式が定数です。
RGY_ERR RGYOutputRaw::Init(const TCHAR *strFileName, const VideoInfo *pVideoOutputInfo, const void *prm) {
    UNREFERENCED_PARAMETER(pVideoOutputInfo);
    RGYOutputRawPrm *rawPrm = (RGYOutputRawPrm *)prm;
    if (!rawPrm->benchmark && _tcslen(strFileName) == 0) {
        AddMessage(RGY_LOG_ERROR, _T("output filename not set.\n"));
        return RGY_ERR_INVALID_PARAM;
    }

    if (rawPrm->benchmark) {
        m_noOutput = true;
        AddMessage(RGY_LOG_DEBUG, _T("no output for benchmark mode.\n"));
    } else {
        if (_tcscmp(strFileName, _T("-")) == 0) {
            m_fDest.reset(stdout);
            m_outputIsStdout = true;
            AddMessage(RGY_LOG_DEBUG, _T("using stdout\n"));
        } else {
            CreateDirectoryRecursive(PathRemoveFileSpecFixed(strFileName).second.c_str());
            FILE *fp = NULL;
            int error = _tfopen_s(&fp, strFileName, _T("wb+"));
            if (error != 0 || fp == NULL) {
                AddMessage(RGY_LOG_ERROR, _T("failed to open output file \"%s\": %s\n"), strFileName, _tcserror(error));
                return RGY_ERR_FILE_OPEN;
            }
            m_fDest.reset(fp);
            AddMessage(RGY_LOG_DEBUG, _T("Opened file \"%s\"\n"), strFileName);

            int bufferSizeByte = clamp(rawPrm->bufSizeMB, 0, RGY_OUTPUT_BUF_MB_MAX) * 1024 * 1024;
            if (bufferSizeByte) {
                void *ptr = nullptr;
                bufferSizeByte = (int)malloc_degeneracy(&ptr, bufferSizeByte, 1024 * 1024);
                if (bufferSizeByte) {
                    m_outputBuffer.reset((char*)ptr);
                    setvbuf(m_fDest.get(), m_outputBuffer.get(), _IOFBF, bufferSizeByte);
                    AddMessage(RGY_LOG_DEBUG, _T("Added %d MB output buffer.\n"), bufferSizeByte / (1024 * 1024));
                }
            }
        }
#if ENABLE_AVSW_READER
        if ((ENCODER_NVENC
            && (pVideoOutputInfo->codec == RGY_CODEC_H264 || pVideoOutputInfo->codec == RGY_CODEC_HEVC)
            && pVideoOutputInfo->sar[0] * pVideoOutputInfo->sar[1] > 0)
            || (ENCODER_VCEENC
                && (pVideoOutputInfo->vui.format != 5
                    || pVideoOutputInfo->vui.colorprim != 2
                    || pVideoOutputInfo->vui.transfer != 2
                    || pVideoOutputInfo->vui.matrix != 2
                    || pVideoOutputInfo->vui.chromaloc != 0))) {
            if (!check_avcodec_dll()) {
                AddMessage(RGY_LOG_ERROR, error_mes_avcodec_dll_not_found());
                return RGY_ERR_NULL_PTR;
            }

            const char *bsf_name = nullptr;
            switch (pVideoOutputInfo->codec) {
            case RGY_CODEC_H264: bsf_name = "h264_metadata"; break;
            case RGY_CODEC_HEVC: bsf_name = "hevc_metadata"; break;
            default:
                break;
            }
            if (bsf_name == nullptr) {
                AddMessage(RGY_LOG_ERROR, _T("invalid codec to set metadata filter.\n"));
                return RGY_ERR_INVALID_CALL;
            }
            AddMessage(RGY_LOG_DEBUG, _T("start initialize %s filter...\n"), bsf_name);
            auto filter = av_bsf_get_by_name(bsf_name);
            if (filter == nullptr) {
                AddMessage(RGY_LOG_ERROR, _T("failed to find %s.\n"), bsf_name);
                return RGY_ERR_NOT_FOUND;
            }
            unique_ptr<AVCodecParameters, RGYAVDeleter<AVCodecParameters>> codecpar(avcodec_parameters_alloc(), RGYAVDeleter<AVCodecParameters>(avcodec_parameters_free));

            codecpar->codec_type              = AVMEDIA_TYPE_VIDEO;
            codecpar->codec_id                = getAVCodecId(pVideoOutputInfo->codec);
            codecpar->width                   = pVideoOutputInfo->dstWidth;
            codecpar->height                  = pVideoOutputInfo->dstHeight;
            codecpar->format                  = csp_rgy_to_avpixfmt(pVideoOutputInfo->csp);
            codecpar->level                   = pVideoOutputInfo->codecLevel;
            codecpar->profile                 = pVideoOutputInfo->codecProfile;
            codecpar->sample_aspect_ratio.num = pVideoOutputInfo->sar[0];
            codecpar->sample_aspect_ratio.den = pVideoOutputInfo->sar[1];
            codecpar->chroma_location         = AVCHROMA_LOC_LEFT;
            codecpar->field_order             = picstrcut_rgy_to_avfieldorder(pVideoOutputInfo->picstruct);
            codecpar->video_delay             = pVideoOutputInfo->videoDelay;
            if (pVideoOutputInfo->vui.descriptpresent) {
                codecpar->color_space         = (AVColorSpace)pVideoOutputInfo->vui.matrix;
                codecpar->color_primaries     = (AVColorPrimaries)pVideoOutputInfo->vui.colorprim;
                codecpar->color_range         = (AVColorRange)(pVideoOutputInfo->vui.fullrange ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG);
                codecpar->color_trc           = (AVColorTransferCharacteristic)pVideoOutputInfo->vui.transfer;
            }
            int ret = 0;
            AVBSFContext *bsfc = nullptr;
            if (0 > (ret = av_bsf_alloc(filter, &bsfc))) {
                AddMessage(RGY_LOG_ERROR, _T("failed to allocate memory for %s: %s.\n"), bsf_name, qsv_av_err2str(ret).c_str());
                return RGY_ERR_NULL_PTR;
            }
            if (0 > (ret = avcodec_parameters_copy(bsfc->par_in, codecpar.get()))) {
                AddMessage(RGY_LOG_ERROR, _T("failed to copy parameter for %s: %s.\n"), bsf_name, qsv_av_err2str(ret).c_str());
                return RGY_ERR_UNKNOWN;
            }
            m_pBsfc = unique_ptr<AVBSFContext, RGYAVDeleter<AVBSFContext>>(bsfc, RGYAVDeleter<AVBSFContext>(av_bsf_free));
            AVDictionary *bsfPrm = nullptr;
            if (ENCODER_NVENC) {
                char sar[128];
                sprintf_s(sar, "%d/%d", pVideoOutputInfo->sar[0], pVideoOutputInfo->sar[1]);
                av_dict_set(&bsfPrm, "sample_aspect_ratio", sar, 0);
                AddMessage(RGY_LOG_DEBUG, _T("set sar %d:%d by %s filter\n"), pVideoOutputInfo->sar[0], pVideoOutputInfo->sar[1], bsf_name);
            }
            if (ENCODER_VCEENC) {
                if (pVideoOutputInfo->vui.format != 5 /*undef*/) {
                    av_dict_set_int(&bsfPrm, "video_format", pVideoOutputInfo->vui.format, 0);
                    AddMessage(RGY_LOG_DEBUG, _T("set video_format %d by %s filter\n"), pVideoOutputInfo->vui.format, bsf_name);
                }
                if (pVideoOutputInfo->vui.colorprim != 2 /*undef*/) {
                    av_dict_set_int(&bsfPrm, "colour_primaries", pVideoOutputInfo->vui.colorprim, 0);
                    AddMessage(RGY_LOG_DEBUG, _T("set colorprim %d by %s filter\n"), pVideoOutputInfo->vui.colorprim, bsf_name);
                }
                if (pVideoOutputInfo->vui.transfer != 2 /*undef*/) {
                    av_dict_set_int(&bsfPrm, "transfer_characteristics", pVideoOutputInfo->vui.transfer, 0);
                    AddMessage(RGY_LOG_DEBUG, _T("set transfer %d by %s filter\n"), pVideoOutputInfo->vui.transfer, bsf_name);
                }
                if (pVideoOutputInfo->vui.matrix != 2 /*undef*/) {
                    av_dict_set_int(&bsfPrm, "matrix_coefficients", pVideoOutputInfo->vui.matrix, 0);
                    AddMessage(RGY_LOG_DEBUG, _T("set matrix %d by %s filter\n"), pVideoOutputInfo->vui.matrix, bsf_name);
                }
                if (pVideoOutputInfo->vui.chromaloc != 0) {
                    av_dict_set_int(&bsfPrm, "chroma_sample_loc_type", pVideoOutputInfo->vui.chromaloc, 0);
                    AddMessage(RGY_LOG_DEBUG, _T("set chromaloc %d by %s filter\n"), pVideoOutputInfo->vui.chromaloc, bsf_name);
                }
            }
            if (0 > (ret = av_opt_set_dict2(m_pBsfc.get(), &bsfPrm, AV_OPT_SEARCH_CHILDREN))) {
                AddMessage(RGY_LOG_ERROR, _T("failed to set parameters for %s: %s.\n"), bsf_name, qsv_av_err2str(ret).c_str());
                return RGY_ERR_UNKNOWN;
            }
            if (0 > (ret = av_bsf_init(m_pBsfc.get()))) {
                AddMessage(RGY_LOG_ERROR, _T("failed to init %s: %s.\n"), bsf_name, qsv_av_err2str(ret).c_str());
                return RGY_ERR_UNKNOWN;
            }
            AddMessage(RGY_LOG_DEBUG, _T("initialized %s filter\n"), bsf_name);
        }
#endif //#if ENABLE_AVSW_READER
        if (rawPrm->codecId == RGY_CODEC_HEVC) {
            m_seiNal = rawPrm->seiNal;
        }
    }
    m_inited = true;
    return RGY_ERR_NONE;
}
#pragma warning (pop)

RGY_ERR RGYOutputRaw::WriteNextFrame(RGYBitstream *pBitstream) {
    if (pBitstream == nullptr) {
        AddMessage(RGY_LOG_ERROR, _T("Invalid call: WriteNextFrame\n"));
        return RGY_ERR_NULL_PTR;
    }

    size_t nBytesWritten = 0;
    if (!m_noOutput) {
#if ENABLE_AVSW_READER
        if (m_pBsfc) {
            uint8_t nal_type = 0;
            std::vector<nal_info> nal_list;
            if (m_VideoOutputInfo.codec == RGY_CODEC_HEVC) {
                nal_type = NALU_HEVC_SPS;
                nal_list = parse_nal_unit_hevc(pBitstream->data(), pBitstream->size());
            } else if (m_VideoOutputInfo.codec == RGY_CODEC_H264) {
                nal_type = NALU_H264_SPS;
                nal_list = parse_nal_unit_h264(pBitstream->data(), pBitstream->size());
            }
            auto sps_nal = std::find_if(nal_list.begin(), nal_list.end(), [](nal_info info) { return info.type == NALU_HEVC_SPS; });
            if (sps_nal != nal_list.end()) {
                AVPacket pkt = { 0 };
                av_init_packet(&pkt);
                av_new_packet(&pkt, (int)sps_nal->size);
                memcpy(pkt.data, sps_nal->ptr, sps_nal->size);
                int ret = 0;
                if (0 > (ret = av_bsf_send_packet(m_pBsfc.get(), &pkt))) {
                    av_packet_unref(&pkt);
                    AddMessage(RGY_LOG_ERROR, _T("failed to send packet to %s bitstream filter: %s.\n"),
                        char_to_tstring(m_pBsfc->filter->name).c_str(), qsv_av_err2str(ret).c_str());
                    return RGY_ERR_UNKNOWN;
                }
                ret = av_bsf_receive_packet(m_pBsfc.get(), &pkt);
                if (ret == AVERROR(EAGAIN)) {
                    return RGY_ERR_NONE;
                } else if ((ret < 0 && ret != AVERROR_EOF) || pkt.size < 0) {
                    AddMessage(RGY_LOG_ERROR, _T("failed to run %s bitstream filter: %s.\n"),
                        char_to_tstring(m_pBsfc->filter->name).c_str(), qsv_av_err2str(ret).c_str());
                    return RGY_ERR_UNKNOWN;
                }
                const auto new_data_size = pBitstream->size() + pkt.size - sps_nal->size;
                const auto sps_nal_offset = sps_nal->ptr - pBitstream->data();
                const auto next_nal_orig_offset = sps_nal_offset + sps_nal->size;
                const auto next_nal_new_offset = sps_nal_offset + pkt.size;
                const auto stream_orig_length = pBitstream->size();
                if ((decltype(new_data_size))pBitstream->bufsize() < new_data_size) {
                    pBitstream->changeSize(new_data_size);
                } else if (pkt.size > (decltype(pkt.size))sps_nal->size) {
                    pBitstream->trim();
                }
                memmove(pBitstream->data() + next_nal_new_offset, pBitstream->data() + next_nal_orig_offset, stream_orig_length - next_nal_orig_offset);
                memcpy(pBitstream->data() + sps_nal_offset, pkt.data, pkt.size);
                av_packet_unref(&pkt);
            }
        }
#endif //#if ENABLE_AVSW_READER
        if (m_seiNal.size()) {
            const auto nal_list     = parse_nal_unit_hevc(pBitstream->data(), pBitstream->size());
            const auto hevc_vps_nal = std::find_if(nal_list.begin(), nal_list.end(), [](nal_info info) { return info.type == NALU_HEVC_VPS; });
            const auto hevc_sps_nal = std::find_if(nal_list.begin(), nal_list.end(), [](nal_info info) { return info.type == NALU_HEVC_SPS; });
            const auto hevc_pps_nal = std::find_if(nal_list.begin(), nal_list.end(), [](nal_info info) { return info.type == NALU_HEVC_PPS; });
            const bool header_check = (nal_list.end() != hevc_vps_nal) && (nal_list.end() != hevc_sps_nal) && (nal_list.end() != hevc_pps_nal);
            if (header_check) {
                nBytesWritten  = _fwrite_nolock(hevc_vps_nal->ptr, 1, hevc_vps_nal->size, m_fDest.get());
                nBytesWritten += _fwrite_nolock(hevc_sps_nal->ptr, 1, hevc_sps_nal->size, m_fDest.get());
                nBytesWritten += _fwrite_nolock(hevc_pps_nal->ptr, 1, hevc_pps_nal->size, m_fDest.get());
                nBytesWritten += _fwrite_nolock(m_seiNal.data(),   1, m_seiNal.size(),    m_fDest.get());
                for (const auto& nal : nal_list) {
                    if (nal.type != NALU_HEVC_VPS && nal.type != NALU_HEVC_SPS && nal.type != NALU_HEVC_PPS) {
                        nBytesWritten += _fwrite_nolock(nal.ptr, 1, nal.size, m_fDest.get());
                    }
                }
            } else {
                AddMessage(RGY_LOG_ERROR, _T("Unexpected HEVC header.\n"));
                return RGY_ERR_UNDEFINED_BEHAVIOR;
            }
            m_seiNal.clear();
        } else {
            nBytesWritten = _fwrite_nolock(pBitstream->data(), 1, pBitstream->size(), m_fDest.get());
            WRITE_CHECK(nBytesWritten, pBitstream->size());
        }
    }

    m_encSatusInfo->SetOutputData(pBitstream->frametype(), pBitstream->size(), 0);
    pBitstream->setSize(0);

    return RGY_ERR_NONE;
}

RGY_ERR RGYOutputRaw::WriteNextFrame(RGYFrame *pSurface) {
    UNREFERENCED_PARAMETER(pSurface);
    return RGY_ERR_UNSUPPORTED;
}

#include "rgy_input_avcodec.h"
#include "rgy_output_avcodec.h"

RGY_ERR initWriters(
    shared_ptr<RGYOutput> &pFileWriter,
    vector<shared_ptr<RGYOutput>>& pFileWriterListAudio,
    shared_ptr<RGYInput> &pFileReader,
    vector<shared_ptr<RGYInput>> &audioReaders,
    RGYParamCommon *common,
    const VideoInfo *input,
    const RGYParamControl *ctrl,
    const VideoInfo outputVideoInfo,
    const sTrimParam& trimParam,
    const rgy_rational<int> outputTimebase,
    const vector<unique_ptr<AVChapter>>& chapters,
    const int subburnTrackId,
    const bool videoDtsUnavailable,
    const bool benchmark,
    shared_ptr<EncodeStatus> pStatus,
    shared_ptr<CPerfMonitor> pPerfMonitor,
    shared_ptr<RGYLog> log
) {
    bool stdoutUsed = false;
    HEVCHDRSei hedrsei;
    if (hedrsei.parse(common->maxCll, common->masterDisplay)) {
        log->write(RGY_LOG_ERROR, _T("Failed to parse HEVC HDR10 metadata.\n"));
        return RGY_ERR_UNSUPPORTED;
    }
#if ENABLE_AVSW_READER
    vector<int> streamTrackUsed; //使用した音声/字幕のトラックIDを保存する
    bool useH264ESOutput =
        ((common->muxOutputFormat.length() > 0 && 0 == _tcscmp(common->muxOutputFormat.c_str(), _T("raw")))) //--formatにrawが指定されている
        || (PathFindExtension(common->outputFilename.c_str()) == nullptr || PathFindExtension(common->outputFilename.c_str())[0] != '.') //拡張子がしない
        || check_ext(common->outputFilename.c_str(), { ".m2v", ".264", ".h264", ".avc", ".avc1", ".x264", ".265", ".h265", ".hevc" }); //特定の拡張子
    if (!useH264ESOutput) {
        common->AVMuxTarget |= RGY_MUX_VIDEO;
    }


    double inputFileDuration = 0.0;
    { auto pAVCodecReader = std::dynamic_pointer_cast<RGYInputAvcodec>(pFileReader);
    if (pAVCodecReader != nullptr) {
        //caption2ass用の解像度情報の提供
        //これをしないと入力ファイルのデータをずっとバッファし続けるので注意
        pAVCodecReader->setOutputVideoInfo(outputVideoInfo.dstWidth, outputVideoInfo.dstHeight,
            outputVideoInfo.sar[0], outputVideoInfo.sar[1],
            (common->AVMuxTarget & RGY_MUX_VIDEO) != 0);
        inputFileDuration = pAVCodecReader->GetInputVideoDuration();
    }
    }
    //if (inputParams->CodecId == MFX_CODEC_RAW) {
    //    inputParams->AVMuxTarget &= ~RGY_MUX_VIDEO;
    //}
    pStatus->Init(outputVideoInfo.fpsN, outputVideoInfo.fpsD, input->frames, inputFileDuration, trimParam, log, pPerfMonitor);
    if (ctrl->perfMonitorSelect || ctrl->perfMonitorSelectMatplot) {
        pPerfMonitor->SetEncStatus(pStatus);
    }

    bool audioCopyAll = false;
    if (common->AVMuxTarget & RGY_MUX_VIDEO) {
        log->write(RGY_LOG_DEBUG, _T("Output: Using avformat writer.\n"));
        pFileWriter = std::make_shared<RGYOutputAvcodec>();
        AvcodecWriterPrm writerPrm;
        writerPrm.outputFormat            = common->muxOutputFormat;
        writerPrm.trimList                = trimParam.list;
        writerPrm.bVideoDtsUnavailable    = videoDtsUnavailable;
        writerPrm.threadOutput           = ctrl->threadOutput;
        writerPrm.threadAudio            = ctrl->threadAudio;
        writerPrm.bufSizeMB              = common->outputBufSizeMB;
        writerPrm.audioResampler         = common->audioResampler;
        writerPrm.audioIgnoreDecodeError = common->audioIgnoreDecodeError;
        writerPrm.queueInfo = (pPerfMonitor) ? pPerfMonitor->GetQueueInfoPtr() : nullptr;
        writerPrm.muxVidTsLogFile         = (ctrl->logMuxVidTsFile) ? ctrl->logMuxVidTsFile : _T("");
        writerPrm.bitstreamTimebase      = av_make_q(outputTimebase);
        writerPrm.HEVCHdrSei             = &hedrsei;
        writerPrm.videoCodecTag           = common->videoCodecTag;
        if (common->muxOpt > 0) {
            writerPrm.muxOpt = *common->muxOpt;
        }
        auto pAVCodecReader = std::dynamic_pointer_cast<RGYInputAvcodec>(pFileReader);
        if (pAVCodecReader != nullptr) {
            writerPrm.inputFormatMetadata = pAVCodecReader->GetInputFormatMetadata();
            if (chapters.size() > 0 && (common->copyChapter || common->chapterFile.length() > 0)) {
                writerPrm.chapterList.clear();
                for (uint32_t i = 0; i < chapters.size(); i++) {
                    writerPrm.chapterList.push_back(chapters[i].get());
                }
            }
            writerPrm.videoInputFirstKeyPts = pAVCodecReader->GetVideoFirstKeyPts();
            writerPrm.videoInputStream = pAVCodecReader->GetInputVideoStream();
        }
        if (common->AVMuxTarget & (RGY_MUX_AUDIO | RGY_MUX_SUBTITLE)) {
            log->write(RGY_LOG_DEBUG, _T("Output: Audio/Subtitle muxing enabled.\n"));
            for (int i = 0; !audioCopyAll && i < common->nAudioSelectCount; i++) {
                //トラック"0"が指定されていれば、すべてのトラックをコピーするということ
                audioCopyAll = (common->ppAudioSelectList[i]->trackID == 0);
            }
            log->write(RGY_LOG_DEBUG, _T("Output: CopyAll=%s\n"), (audioCopyAll) ? _T("true") : _T("false"));
            pAVCodecReader = std::dynamic_pointer_cast<RGYInputAvcodec>(pFileReader);
            vector<AVDemuxStream> streamList;
            if (pAVCodecReader) {
                streamList = pAVCodecReader->GetInputStreamInfo();
            }

            for (auto& stream : streamList) {
                const auto streamMediaType = trackMediaType(stream.trackId);
                //audio-fileで別ファイルとして抽出するものは除く
                bool usedInAudioFile = false;
                for (int i = 0; i < (int)common->nAudioSelectCount; i++) {
                    if (trackID(stream.trackId) == common->ppAudioSelectList[i]->trackID
                        && common->ppAudioSelectList[i]->extractFilename.length() > 0) {
                        usedInAudioFile = true;
                    }
                }
                if (usedInAudioFile) {
                    continue;
                }
                const AudioSelect *pAudioSelect = nullptr;
                for (int i = 0; i < (int)common->nAudioSelectCount; i++) {
                    if (trackID(stream.trackId) == common->ppAudioSelectList[i]->trackID
                        && common->ppAudioSelectList[i]->extractFilename.length() == 0) {
                        pAudioSelect = common->ppAudioSelectList[i];
                        break;
                    }
                }
                if (pAudioSelect == nullptr) {
                    //一致するTrackIDがなければ、trackID = 0 (全指定)を探す
                    for (int i = 0; i < common->nAudioSelectCount; i++) {
                        if (common->ppAudioSelectList[i]->trackID == 0
                            && common->ppAudioSelectList[i]->extractFilename.length() == 0) {
                            pAudioSelect = common->ppAudioSelectList[i];
                            break;
                        }
                    }
                }
                const SubtitleSelect *pSubtitleSelect = nullptr;
                if (streamMediaType == AVMEDIA_TYPE_SUBTITLE) {
                    for (int i = 0; i < common->nSubtitleSelectCount; i++) {
                        if (trackID(stream.trackId) == common->ppSubtitleSelectList[i]->trackID) {
                            pSubtitleSelect = common->ppSubtitleSelectList[i];
                            break;
                        }
                    }
                    if (pSubtitleSelect == nullptr) {
                        //一致するTrackIDがなければ、trackID = 0 (全指定)を探す
                        for (int i = 0; i < common->nSubtitleSelectCount; i++) {
                            if (common->ppAudioSelectList[i]->trackID == 0) {
                                pSubtitleSelect = common->ppSubtitleSelectList[i];
                                break;
                            }
                        }
                    }
                }
                const DataSelect *pDataSelect = nullptr;
                if (streamMediaType == AVMEDIA_TYPE_DATA) {
                    for (int i = 0; i < common->nDataSelectCount; i++) {
                        if (trackID(stream.trackId) == common->ppDataSelectList[i]->trackID) {
                            pDataSelect = common->ppDataSelectList[i];
                        }
                    }
                    if (pSubtitleSelect == nullptr) {
                        //一致するTrackIDがなければ、trackID = 0 (全指定)を探す
                        for (int i = 0; i < common->nDataSelectCount; i++) {
                            if (common->ppDataSelectList[i]->trackID == 0) {
                                pDataSelect = common->ppDataSelectList[i];
                                break;
                            }
                        }
                    }
                }
                if (pAudioSelect != nullptr || audioCopyAll || streamMediaType != AVMEDIA_TYPE_AUDIO) {
                    streamTrackUsed.push_back(stream.trackId);
                    if (streamMediaType == AVMEDIA_TYPE_SUBTITLE && subburnTrackId > 0) {
                        continue;
                    }
                    AVOutputStreamPrm prm;
                    prm.src = stream;
                    //pAudioSelect == nullptrは "copyAllStreams" か 字幕ストリーム によるもの
                    if (pAudioSelect != nullptr) {
                        prm.decodeCodecPrm = pAudioSelect->decCodecPrm;
                        prm.bitrate = pAudioSelect->encBitrate;
                        prm.samplingRate = pAudioSelect->encSamplingRate;
                        prm.encodeCodec = pAudioSelect->encCodec;
                        prm.encodeCodecPrm = pAudioSelect->encCodecPrm;
                        prm.encodeCodecProfile = pAudioSelect->encCodecProfile;
                        prm.filter = pAudioSelect->filter;
                    }
                    if (pSubtitleSelect != nullptr) {
                        prm.encodeCodec = pSubtitleSelect->encCodec;
                        prm.encodeCodecPrm = pSubtitleSelect->encCodecPrm;
                        prm.asdata = pSubtitleSelect->asdata;
                    }
                    log->write(RGY_LOG_DEBUG, _T("Output: Added %s track#%d (stream idx %d) for mux, bitrate %d, codec: %s %s %s\n"),
                        char_to_tstring(av_get_media_type_string(streamMediaType)).c_str(),
                        stream.trackId, stream.index, prm.bitrate, prm.encodeCodec.c_str(),
                        prm.encodeCodecProfile.c_str(),
                        prm.encodeCodecPrm.c_str());
                    writerPrm.inputStreamList.push_back(std::move(prm));
                }
            }
            vector<AVDemuxStream> audioSrcStreams;
            for (const auto &audioReader : audioReaders) {
                if (audioReader->GetAudioTrackCount()) {
                    auto pAVCodecAudioReader = std::dynamic_pointer_cast<RGYInputAvcodec>(audioReader);
                    if (pAVCodecAudioReader) {
                        vector_cat(audioSrcStreams, pAVCodecAudioReader->GetInputStreamInfo());
                    }
                    //もしavqsvリーダーでないなら、音声リーダーから情報を取得する必要がある
                    if (pAVCodecReader == nullptr) {
                        writerPrm.videoInputFirstKeyPts = pAVCodecAudioReader->GetVideoFirstKeyPts();
                        writerPrm.videoInputStream = pAVCodecAudioReader->GetInputVideoStream();
                    }
                }
            }
            for (auto &stream : audioSrcStreams) {
                const auto streamMediaType = trackMediaType(stream.trackId);
                //audio-fileで別ファイルとして抽出するものは除く
                bool usedInAudioFile = false;
                for (const auto &audsrc : common->audioSource) {
                    for (const auto &audsel : audsrc.select) {
                        if (trackID(stream.trackId) == audsel.first
                            && audsel.second.extractFilename.length() > 0) {
                            usedInAudioFile = true;
                        }
                    }
                }
                if (usedInAudioFile) {
                    continue;
                }
                const AudioSelect *pAudioSelect = nullptr;
                for (const auto &audsrc : common->audioSource) {
                    for (const auto &audsel : audsrc.select) {
                        if (audsel.first == trackID(stream.trackId)) {
                            pAudioSelect = &audsel.second;
                            break;
                        }
                    }
                }
                if (pAudioSelect == nullptr) {
                    //一致するTrackIDがなければ、trackID = 0 (全指定)を探す
                    for (const auto &audsrc : common->audioSource) {
                        for (const auto &audsel : audsrc.select) {
                            if (audsel.first == 0) {
                                pAudioSelect = &audsel.second;
                                break;
                            }
                        }
                    }
                }
                if (pAudioSelect != nullptr || audioCopyAll) {
                    streamTrackUsed.push_back(stream.trackId);
                    AVOutputStreamPrm prm;
                    prm.src = stream;
                    //pAudioSelect == nullptrは "copyAllStreams" か 字幕ストリーム によるもの
                    if (pAudioSelect != nullptr) {
                        prm.decodeCodecPrm = pAudioSelect->decCodecPrm;
                        prm.bitrate = pAudioSelect->encBitrate;
                        prm.samplingRate = pAudioSelect->encSamplingRate;
                        prm.encodeCodec = pAudioSelect->encCodec;
                        prm.encodeCodecPrm = pAudioSelect->encCodecPrm;
                        prm.encodeCodecProfile = pAudioSelect->encCodecProfile;
                        prm.filter = pAudioSelect->filter;
                    }
                    log->write(RGY_LOG_DEBUG, _T("Output: Added %s track#%d (stream idx %d) for mux, bitrate %d, codec: %s %s %s\n"),
                        char_to_tstring(av_get_media_type_string(streamMediaType)).c_str(),
                        stream.trackId, stream.index, prm.bitrate, prm.encodeCodec.c_str(),
                        prm.encodeCodecProfile.c_str(),
                        prm.encodeCodecPrm.c_str());
                    writerPrm.inputStreamList.push_back(std::move(prm));
                }
            }
            vector_cat(streamList, audioSrcStreams);
        }
        auto sts = pFileWriter->Init(common->outputFilename.c_str(), &outputVideoInfo, &writerPrm, log, pStatus);
        if (sts != RGY_ERR_NONE) {
            log->write(RGY_LOG_ERROR, pFileWriter->GetOutputMessage());
            return sts;
        } else if (common->AVMuxTarget & (RGY_MUX_AUDIO | RGY_MUX_SUBTITLE)) {
            pFileWriterListAudio.push_back(pFileWriter);
        }
        stdoutUsed = pFileWriter->outputStdout();
        log->write(RGY_LOG_DEBUG, _T("Output: Initialized avformat writer%s.\n"), (stdoutUsed) ? _T("using stdout") : _T(""));
    } else if (common->AVMuxTarget & (RGY_MUX_AUDIO | RGY_MUX_SUBTITLE)) {
        log->write(RGY_LOG_ERROR, _T("Audio mux cannot be used alone, should be use with video mux.\n"));
        return RGY_ERR_UNKNOWN;
    } else {
#endif //ENABLE_AVSW_READER
        pFileWriter = std::make_shared<RGYOutputRaw>();
        RGYOutputRawPrm rawPrm;
        rawPrm.bufSizeMB = common->outputBufSizeMB;
        rawPrm.benchmark = benchmark;
        rawPrm.codecId = outputVideoInfo.codec;
        rawPrm.seiNal = hedrsei.gen_nal();
        auto sts = pFileWriter->Init(common->outputFilename.c_str(), &outputVideoInfo, &rawPrm, log, pStatus);
        if (sts != RGY_ERR_NONE) {
            log->write(RGY_LOG_ERROR, pFileWriter->GetOutputMessage());
            return sts;
        }
        stdoutUsed = pFileWriter->outputStdout();
        log->write(RGY_LOG_DEBUG, _T("Output: Initialized bitstream writer%s.\n"), (stdoutUsed) ? _T("using stdout") : _T(""));
#if ENABLE_AVSW_READER
    }

    //音声の抽出
    if (common->nAudioSelectCount + common->nSubtitleSelectCount - (audioCopyAll ? 1 : 0) > (int)streamTrackUsed.size()) {
        log->write(RGY_LOG_DEBUG, _T("Output: Audio file output enabled.\n"));
        auto pAVCodecReader = std::dynamic_pointer_cast<RGYInputAvcodec>(pFileReader);
        if (pAVCodecReader == nullptr) {
            log->write(RGY_LOG_ERROR, _T("Audio output is only supported with transcoding (avhw/avsw reader).\n"));
            return RGY_ERR_INVALID_PARAM;
        } else {
            auto inutAudioInfoList = pAVCodecReader->GetInputStreamInfo();
            for (auto& audioTrack : inutAudioInfoList) {
                bool bTrackAlreadyUsed = false;
                for (auto usedTrack : streamTrackUsed) {
                    if (usedTrack == audioTrack.trackId) {
                        bTrackAlreadyUsed = true;
                        log->write(RGY_LOG_DEBUG, _T("Audio track #%d is already set to be muxed, so cannot be extracted to file.\n"), trackID(audioTrack.trackId));
                        break;
                    }
                }
                if (bTrackAlreadyUsed) {
                    continue;
                }
                const AudioSelect *pAudioSelect = nullptr;
                for (int i = 0; i < (int)common->nAudioSelectCount; i++) {
                    if (trackID(audioTrack.trackId) == common->ppAudioSelectList[i]->trackID
                        && common->ppAudioSelectList[i]->extractFilename.length() > 0) {
                        pAudioSelect = common->ppAudioSelectList[i];
                    }
                }
                if (pAudioSelect == nullptr) {
                    log->write(RGY_LOG_ERROR, _T("Audio track #%d is not used anyware, this should not happen.\n"), trackID(audioTrack.trackId));
                    return RGY_ERR_UNKNOWN;
                }
                log->write(RGY_LOG_DEBUG, _T("Output: Output audio track #%d (stream index %d) to \"%s\", format: %s, codec %s, bitrate %d\n"),
                    trackID(audioTrack.trackId), audioTrack.index, pAudioSelect->extractFilename.c_str(), pAudioSelect->extractFormat.c_str(), pAudioSelect->encCodec.c_str(), pAudioSelect->encBitrate);

                AVOutputStreamPrm prm;
                prm.src = audioTrack;
                //pAudioSelect == nullptrは "copyAll" によるもの
                prm.bitrate = pAudioSelect->encBitrate;
                prm.filter = pAudioSelect->filter;
                prm.encodeCodec = pAudioSelect->encCodec;
                prm.samplingRate = pAudioSelect->encSamplingRate;

                AvcodecWriterPrm writerAudioPrm;
                writerAudioPrm.threadOutput   = ctrl->threadOutput;
                writerAudioPrm.threadAudio    = ctrl->threadAudio;
                writerAudioPrm.bufSizeMB      = common->outputBufSizeMB;
                writerAudioPrm.outputFormat   = pAudioSelect->extractFormat;
                writerAudioPrm.audioIgnoreDecodeError = common->audioIgnoreDecodeError;
                writerAudioPrm.audioResampler = common->audioResampler;
                writerAudioPrm.inputStreamList.push_back(prm);
                writerAudioPrm.trimList = trimParam.list;
                writerAudioPrm.videoInputFirstKeyPts = pAVCodecReader->GetVideoFirstKeyPts();
                writerAudioPrm.videoInputStream = pAVCodecReader->GetInputVideoStream();
                writerAudioPrm.bitstreamTimebase = av_make_q(outputTimebase);

                shared_ptr<RGYOutput> pWriter = std::make_shared<RGYOutputAvcodec>();
                auto sts = pWriter->Init(pAudioSelect->extractFilename.c_str(), nullptr, &writerAudioPrm, log, pStatus);
                if (sts != RGY_ERR_NONE) {
                    log->write(RGY_LOG_ERROR, pWriter->GetOutputMessage());
                    return sts;
                }
                log->write(RGY_LOG_DEBUG, _T("Output: Intialized audio output for track #%d.\n"), trackID(audioTrack.trackId));
                bool audioStdout = pWriter->outputStdout();
                if (stdoutUsed && audioStdout) {
                    log->write(RGY_LOG_ERROR, _T("Multiple stream outputs are set to stdout, please remove conflict.\n"));
                    return RGY_ERR_UNKNOWN;
                }
                stdoutUsed |= audioStdout;
                pFileWriterListAudio.push_back(std::move(pWriter));
            }
        }
    }
#endif //ENABLE_AVSW_READER
    return RGY_ERR_NONE;
}
