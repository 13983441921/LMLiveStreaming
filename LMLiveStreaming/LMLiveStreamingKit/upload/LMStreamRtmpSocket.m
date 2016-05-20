//
//  LMStreamRtmpSocket.m
//  LMLiveStreaming
//
//  Created by admin on 16/5/18.
//  Copyright © 2016年 live Interactive. All rights reserved.
//

#import "LMStreamRtmpSocket.h"
#import "rtmp.h"

//static const NSInteger RetryTimesBreaken = 60;///<  重连3分钟  3秒一次 一共60次
//static const NSInteger RetryTimesMargin = 3;

#define DATA_ITEMS_MAX_COUNT 100
#define RTMP_DATA_RESERVE_SIZE 400

#define RTMP_CONNECTION_TIMEOUT 1500
#define RTMP_RECEIVE_TIMEOUT    2
#define RTMP_HEAD_SIZE (sizeof(RTMPPacket)+RTMP_MAX_HEADER_SIZE)

@interface LMStreamRtmpSocket ()<LMStreamingBufferDelegate>
{
    RTMP* _rtmp;
}
@property (nonatomic, weak) id<LMStreamSocketDelegate> delegate;
@property (nonatomic, strong) LMStream *stream;
@property (nonatomic, strong) LMStreamingBuffer *buffer;
@property (nonatomic, strong) dispatch_queue_t socketQueue;
@property (nonatomic, assign) NSInteger retryTimes4netWorkBreaken;

@property (nonatomic, assign) BOOL isSending;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, assign) BOOL isReconnecting;

@property (nonatomic, assign) BOOL sendVideoHead;
@property (nonatomic, assign) BOOL sendAudioHead;

@property (nonatomic, strong) LMStreamDebug *debugInfo;
@property (nonatomic, assign) BOOL showStremDebug;

@end

@implementation LMStreamRtmpSocket

#pragma mark -- LFStreamSocket
- (instancetype)initWithStream:(LMStream*)stream{
    if(!stream) @throw [NSException exceptionWithName:@"LFStreamRtmpSocket init error" reason:@"stream is nil" userInfo:nil];
    if(self = [super init]){
        _stream = stream;
    }
    return self;
}

- (void) start{
    dispatch_async(self.socketQueue, ^{
        if(!_stream) return;
        if(_isConnecting) return;
        [self clean];
        if(self.showStremDebug){
            self.debugInfo.streamId = self.stream.streamId;
            self.debugInfo.uploadUrl = self.stream.url;
            self.debugInfo.videoSize = self.stream.videoSize;
            self.debugInfo.isRtmp = YES;
        }
        [self RTMP264_Connect:(char*)[_stream.url cStringUsingEncoding:NSASCIIStringEncoding]];
    });
}

- (void) stop{
    dispatch_async(self.socketQueue, ^{
        if(_rtmp != NULL){
            RTMP_Close(_rtmp);
            RTMP_Free(_rtmp);
            _rtmp = NULL;
        }
        [self clean];
    });
}

- (void) sendFrame:(LMFrame*)frame{
    __weak typeof(self) _self = self;
    dispatch_async(self.socketQueue, ^{
        __strong typeof(_self) self = _self;
        if(!frame) return;
        [self.buffer appendObject:frame];
        [self sendFrame];
    });
}

- (void)setShowDebug:(BOOL)showDebug{
    _showStremDebug = showDebug;
}

- (void) setDelegate:(id<LMStreamSocketDelegate>)delegate{
    _delegate = delegate;
}

#pragma mark -- CustomMethod
- (void)sendFrame{
    if(!self.isSending && self.buffer.list.count > 0){
        self.isSending = YES;
    
        if(!_isConnected ||  _isReconnecting || _isConnecting || !_rtmp) return;
    
        // 调用发送接口
        LMFrame *frame = [self.buffer popFirstObject];
        
        if(self.showStremDebug){
            self.debugInfo.dataFlow += frame.data.length;
            if(CACurrentMediaTime()*1000 - self.debugInfo.timeStamp < 1000) {
                self.debugInfo.bandwidth += frame.data.length;
                if([frame isKindOfClass:[LMAudioFrame class]]){
                    self.debugInfo.capturedAudioCount ++;
                }else{
                    self.debugInfo.capturedVideoCount ++;
                }
                self.debugInfo.unSendCount = self.buffer.list.count;
            }else {
                self.debugInfo.currentBandwidth = self.debugInfo.bandwidth;
                self.debugInfo.currentCapturedAudioCount = self.debugInfo.capturedAudioCount;
                self.debugInfo.currentCapturedVideoCount = self.debugInfo.capturedVideoCount;
                if(self.delegate && [self.delegate respondsToSelector:@selector(socketDebug:debugInfo:)]){
                    [self.delegate socketDebug:self debugInfo:self.debugInfo];
                }
                
                self.debugInfo.bandwidth = 0;
                self.debugInfo.capturedAudioCount = 0;
                self.debugInfo.capturedVideoCount = 0;
                self.debugInfo.timeStamp = CACurrentMediaTime()*1000;
            }
        }
        
        if([frame isKindOfClass:[LMVideoFrame class]]){
            if(!self.sendVideoHead){
                self.sendVideoHead = YES;
                [self sendVideoHeader:(LMVideoFrame*)frame];
            }else{
                [self sendVideo:(LMVideoFrame*)frame];
            }
        }else{
            if(!self.sendAudioHead){
                self.sendAudioHead = YES;
                [self sendAudioHeader:(LMAudioFrame*)frame];
            }else{
                [self sendAudio:frame];
            }
            
        }
    }
}

- (void)clean{
    _isConnecting = NO;
    _isReconnecting = NO;
    _isSending = NO;
    _isConnected = NO;
    _sendAudioHead = NO;
    _sendVideoHead = NO;
    [self.buffer removeAllObject];
    self.retryTimes4netWorkBreaken = 0;
    self.debugInfo = nil;
}


-(NSInteger) RTMP264_Connect:(char *)push_url{
    //由于摄像头的timestamp是一直在累加，需要每次得到相对时间戳
    //分配与初始化
    if(_isConnecting) return -1;
    
    _isConnecting = YES;
    if(self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]){
        [self.delegate socketStatus:self status:LMStreamStateConnecting];
    }
    
    if(_rtmp != NULL){
        RTMP_Close(_rtmp);
        RTMP_Free(_rtmp);
        _rtmp = NULL;
    }
    
    _rtmp = RTMP_Alloc();
    RTMP_Init(_rtmp);
    
    //设置URL
    if (RTMP_SetupURL(_rtmp, push_url) < 0){
        //log(LOG_ERR, "RTMP_SetupURL() failed!");
        goto Failed;
    }
    
    //设置可写，即发布流，这个函数必须在连接前使用，否则无效
    RTMP_EnableWrite(_rtmp);
    _rtmp->Link.timeout = RTMP_RECEIVE_TIMEOUT;
    
    //连接服务器
    if (RTMP_Connect(_rtmp, NULL) < 0){
        goto Failed;
    }
    
    //连接流
    if (RTMP_ConnectStream(_rtmp, 0) < 0) {
        goto Failed;
    }
    
    if(self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]){
        [self.delegate socketStatus:self status:LMStreamStateConnected];
    }
    
    _isConnected = YES;
    _isConnecting = NO;
    _isReconnecting = NO;
    _isSending = NO;
    _retryTimes4netWorkBreaken = 0;
    return 0;
    
Failed:
    RTMP_Close(_rtmp);
    RTMP_Free(_rtmp);
    [self clean];
    if(self.delegate && [self.delegate respondsToSelector:@selector(socketStatus:status:)]){
        [self.delegate socketStatus:self status:LMStreamStateError];
    }
    return -1;
}

#pragma mark -- Rtmp Send
- (void)sendVideoHeader:(LMVideoFrame*)videoFrame{
    if(!videoFrame || !videoFrame.sps || !videoFrame.pps) return;
    
    unsigned char * body=NULL;
    NSInteger iIndex = 0;
    NSInteger rtmpLength = 1024;
    const char *sps = videoFrame.sps.bytes;
    const char *pps = videoFrame.pps.bytes;
    NSInteger sps_len = videoFrame.sps.length;
    NSInteger pps_len = videoFrame.pps.length;

    body = (unsigned char*)malloc(rtmpLength);
    memset(body,0,rtmpLength);
    
    body[iIndex++] = 0x17;
    body[iIndex++] = 0x00;
    
    body[iIndex++] = 0x00;
    body[iIndex++] = 0x00;
    body[iIndex++] = 0x00;
    
    body[iIndex++] = 0x01;
    body[iIndex++] = sps[1];
    body[iIndex++] = sps[2];
    body[iIndex++] = sps[3];
    body[iIndex++] = 0xff;
    
    /*sps*/
    body[iIndex++]   = 0xe1;
    body[iIndex++] = (sps_len >> 8) & 0xff;
    body[iIndex++] = sps_len & 0xff;
    memcpy(&body[iIndex],sps,sps_len);
    iIndex +=  sps_len;
    
    /*pps*/
    body[iIndex++]   = 0x01;
    body[iIndex++] = (pps_len >> 8) & 0xff;
    body[iIndex++] = (pps_len) & 0xff;
    memcpy(&body[iIndex], pps, pps_len);
    iIndex +=  pps_len;
    
    [self sendPacket:RTMP_PACKET_TYPE_VIDEO data:body size:iIndex nTimestamp:0];
    free(body);
}


- (void)sendVideo:(LMVideoFrame*)frame{
    if(!frame || !frame.data || frame.data.length < 11) return;
    
    NSInteger i = 0;
    NSInteger rtmpLength = frame.data.length+9;
    unsigned char *body = (unsigned char*)malloc(rtmpLength);
    memset(body,0,rtmpLength);
    
    if(frame.isKeyFrame){
        body[i++] = 0x17;// 1:Iframe  7:AVC
    } else{
        body[i++] = 0x27;// 2:Pframe  7:AVC
    }
    body[i++] = 0x01;// AVC NALU
    body[i++] = 0x00;
    body[i++] = 0x00;
    body[i++] = 0x00;
    body[i++] = (frame.data.length >> 24) & 0xff;
    body[i++] = (frame.data.length >> 16) & 0xff;
    body[i++] = (frame.data.length >>  8) & 0xff;
    body[i++] = (frame.data.length ) & 0xff;
    memcpy(&body[i],frame.data.bytes,frame.data.length);
    
    [self sendPacket:RTMP_PACKET_TYPE_VIDEO data:body size:(rtmpLength) nTimestamp:frame.timestamp];
    free(body);
}

-(NSInteger) sendPacket:(unsigned int)nPacketType data:(unsigned char *)data size:(NSInteger) size nTimestamp:(uint64_t) nTimestamp{
    NSInteger rtmpLength = size;
    RTMPPacket rtmp_pack;
    RTMPPacket_Reset(&rtmp_pack);
    RTMPPacket_Alloc(&rtmp_pack,(uint32_t)rtmpLength);
    
    rtmp_pack.m_nBodySize = (uint32_t)size;
    memcpy(rtmp_pack.m_body,data,size);
    rtmp_pack.m_hasAbsTimestamp = 0;
    rtmp_pack.m_packetType = nPacketType;
    if(_rtmp) rtmp_pack.m_nInfoField2 = _rtmp->m_stream_id;
    rtmp_pack.m_nChannel = 0x04;
    rtmp_pack.m_headerType = RTMP_PACKET_SIZE_LARGE;
    if (RTMP_PACKET_TYPE_AUDIO == nPacketType && size !=4){
        rtmp_pack.m_headerType = RTMP_PACKET_SIZE_MEDIUM;
    }
    rtmp_pack.m_nTimeStamp = (uint32_t)nTimestamp;
    
    NSInteger nRet = [self RtmpPacketSend:&rtmp_pack];
    
    RTMPPacket_Free(&rtmp_pack);
    return nRet;
}

- (NSInteger)RtmpPacketSend:(RTMPPacket*)packet{
    if (RTMP_IsConnected(_rtmp)){
        int success = RTMP_SendPacket(_rtmp,packet,0);
        if(success){
            self.isSending = NO;
            [self sendFrame];
        }
        return success;
    }
    
    return -1;
}

- (void)sendAudioHeader:(LMAudioFrame*)audioFrame{
    if(!audioFrame || !audioFrame.audioInfo) return;
    
    NSInteger rtmpLength = audioFrame.audioInfo.length + 2;/*spec data长度,一般是2*/
    unsigned char * body = (unsigned char*)malloc(rtmpLength);
    memset(body,0,rtmpLength);
    
    /*AF 00 + AAC RAW data*/
    body[0] = 0xAF;
    body[1] = 0x00;
    memcpy(&body[2],audioFrame.audioInfo.bytes,audioFrame.audioInfo.length); /*spec_buf是AAC sequence header数据*/
    [self sendPacket:RTMP_PACKET_TYPE_AUDIO data:body size:rtmpLength nTimestamp:0];
    free(body);
}

- (void)sendAudio:(LMFrame*)frame{
    if(!frame) return;
    
    NSInteger rtmpLength = frame.data.length + 2;/*spec data长度,一般是2*/
    unsigned char * body = (unsigned char*)malloc(rtmpLength);
    memset(body,0,rtmpLength);
    
    /*AF 01 + AAC RAW data*/
    body[0] = 0xAF;
    body[1] = 0x01;
    memcpy(&body[2],frame.data.bytes,frame.data.length);
    [self sendPacket:RTMP_PACKET_TYPE_AUDIO data:body size:rtmpLength nTimestamp:frame.timestamp];
    free(body);
}


#pragma mark -- Getter Setter
- (dispatch_queue_t)socketQueue{
    if(!_socketQueue){
        _socketQueue = dispatch_queue_create("com.youku.LMStreaming.live.socketQueue", NULL);
    }
    return _socketQueue;
}

- (LMStreamingBuffer*)buffer{
    if(!_buffer){
        _buffer = [[LMStreamingBuffer alloc] init];
        _buffer.delegate = self;
    }
    return _buffer;
}

- (LMStreamDebug*)debugInfo{
    if(!_debugInfo){
        _debugInfo = [[LMStreamDebug alloc] init];
    }
    return _debugInfo;
}

@end
