'*
'* A wrapper around a video player that implements our screen interface.
'*

'** Credit: Plex Roku https://github.com/plexinc/roku-client-public

'**********************************************************
'** Play video
'**********************************************************

Sub playVideo(video As Object, options as Object) 

    if AudioPlayer().IsPlaying
        Debug("Stop audio player")
        AudioPlayer().Stop()
    end if

	list = []

    if options.playstart = 0 and options.intros <> false

        intros = getVideoIntros(video.Id)

        if intros <> invalid
		
            for each i in intros.Items	

				i.playOptions = {}
				list.push(i)
            end for
			
        end if

    end if

	list.push(video)
	video.playOptions = options
	playVideoList(list)
	
End Sub

Function createVideoPlayerScreen(metadata, playOptions, viewController)

	obj = CreateObject("roAssociativeArray")
    initBaseScreen(obj, viewController)

    obj.Item = metadata

    obj.Show = videoPlayerShow
    obj.HandleMessage = videoPlayerHandleMessage
    obj.OnTimerExpired = videoPlayerOnTimerExpired

    obj.PlayOptions = playOptions
    obj.CreateVideoPlayer = videoPlayerCreateVideoPlayer

	obj.StartTranscodeSessionRequest = videoPlayerStartTranscodeSessionRequest
	obj.OnUrlEvent = videoPlayerOnUrlEvent

    obj.pingTimer = invalid
    obj.lastPosition = 0
    obj.playbackError = false
    obj.underrunCount = 0
    obj.playbackTimer = createTimer()
    obj.timelineTimer = invalid
    obj.progressTimer = invalid
    obj.playState = "buffering"
    obj.bufferingTimer = createTimer()

    obj.ShowPlaybackError = videoPlayerShowPlaybackError
    obj.UpdateNowPlaying = videoPlayerUpdateNowPlaying

    obj.Pause = videoPlayerPause
    obj.Resume = videoPlayerResume
    obj.Next = videoPlayerNext
    obj.Prev = videoPlayerPrev
    obj.Stop = videoPlayerStop
    obj.Seek = videoPlayerSeek

	obj.ReportPlayback = videoPlayerReportPlayback

	obj.ConstructVideoItem = videoPlayerConstructVideoItem
	obj.StopTranscoding = videoPlayerStopTranscoding

    return obj
End Function

Function VideoPlayer()
    ' If the active screen is a slideshow, return it. Otherwise, invalid.
    screen = GetViewController().screens.Peek()
    if type(screen.Screen) = "roVideoScreen" then
        return screen
    else
        return invalid
    end if
End Function

Sub videoPlayerShow()
    ' We only fall back automatically if we originally tried to Direct Play
    ' and the preference allows fallback. One potential quirk is that we do
    ' fall back if there was progress on the Direct Play attempt. This should
    ' be quite uncommon, but if something happens part way through the file
    ' that the device can't handle, we at least give transcoding (from there)
    ' a shot.

    if NOT m.playbackError then
        m.Screen = m.CreateVideoPlayer()

    else
        Debug("Error while playing video, nothing left to fall back to")
        m.ShowPlaybackError()
        m.Screen = invalid
        m.popOnActivate = true
    end if

    if m.Screen <> invalid then
        if m.IsTranscoded then
            Debug("Starting to play transcoded video")
        else
            Debug("Starting to direct play video")
        end if

        m.timelineTimer = createTimer()
        m.timelineTimer.Name = "timeline"
        m.timelineTimer.SetDuration(15000, true)
        m.ViewController.AddTimer(m.timelineTimer, m)

        m.progressTimer = createTimer()
        m.progressTimer.Name = "progress"
        m.progressTimer.SetDuration(2000, true)
        m.ViewController.AddTimer(m.progressTimer, m)

        m.playbackTimer.Mark()
        m.Screen.Show()
        NowPlayingManager().location = "fullScreenVideo"
    else
        m.ViewController.PopScreen(m)
        NowPlayingManager().location = "navigation"
    end if
End Sub

Function videoPlayerCreateVideoPlayer()

    Debug("MediaPlayer::playVideo: Displaying video: " + tostr(m.Item.title))

    videoItem = m.ConstructVideoItem(m.Item, m.PlayOptions)

    player = CreateObject("roVideoScreen")
    player.SetMessagePort(m.Port)

    player.SetPositionNotificationPeriod(1)

    m.IsTranscoded = videoItem.StreamInfo.IsDirectStream <> true
    m.videoItem = videoItem

	player.SetContent(videoItem)

	if m.IsTranscoded then
		m.playMethod = "Transcode"
		m.canSeek = false
		videoItem.StreamStartTimeOffset = m.PlayOptions.playstart
	else
		m.playMethod = "DirectStream"
		m.canSeek = true
	end if

    return player
End Function

Sub videoPlayerShowPlaybackError()
    dialog = createBaseDialog()

    dialog.Title = "Video Unavailable"
    dialog.Text = "We're unable to play this video, make sure the server is running and has access to this video."

    dialog.Show()
End Sub

Function videoPlayerHandleMessage(msg) As Boolean

    handled = false

    if type(msg) = "roVideoScreenEvent" then

        handled = true

        if msg.isScreenClosed() then

            m.timelineTimer.Active = false
            m.progressTimer.Active = false
            m.playState = "stopped"
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isScreenClosed: position -> " + tostr(m.lastPosition))
            NowPlayingManager().location = "navigation"

			m.ReportPlayback("stop")
            m.UpdateNowPlaying()
            if m.IsTranscoded then m.StopTranscoding()

            m.ViewController.PopScreen(m)

        else if msg.isStatusMessage() then
            print "Video status: "; msg.GetIndex(); " " msg.GetData()

        else if msg.isButtonPressed()
            print "Button pressed: "; msg.GetIndex(); " " msg.GetData()

        else if msg.isStreamStarted() then
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isStreamStarted: position -> " + tostr(m.lastPosition))
            Debug("Message data -> " + tostr(msg.GetInfo()))

            if msg.GetInfo().IsUnderrun = true then
                m.underrunCount = m.underrunCount + 1
                if m.underrunCount = 4 then
                    Debug ("Video is underrun")
                end if
            end if

			m.ReportPlayback("start")

			m.StartTranscodeSessionRequest()

        else if msg.isPlaybackPosition() then

            if m.bufferingTimer <> invalid then
                'AnalyticsTracker().TrackTiming(m.bufferingTimer.GetElapsedMillis(), "buffering", tostr(m.IsTranscoded), m.Item.mediaContainerIdentifier)
                m.bufferingTimer = invalid
            end if

            m.lastPosition = msg.GetIndex()

            Debug("MediaPlayer::playVideo::VideoScreenEvent::isPlaybackPosition: set progress -> " + tostr(m.lastPosition))

            m.playState = "playing"
            m.UpdateNowPlaying(true)
			m.ReportPlayback("progress")

        else if msg.isRequestFailed() then
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isRequestFailed - message = " + tostr(msg.GetMessage()))
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isRequestFailed - data = " + tostr(msg.GetData()))
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isRequestFailed - index = " + tostr(msg.GetIndex()))
            m.playbackError = true

        else if msg.isPaused() then
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isPaused: position -> " + tostr(m.lastPosition))
            m.playState = "paused"
            m.UpdateNowPlaying("progress")
			m.ReportPlayback("progress")

        else if msg.isResumed() then
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isResumed")
            m.playState = "playing"
            m.UpdateNowPlaying()
			m.ReportPlayback("progress")

        else if msg.isPartialResult() then
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isPartialResult: position -> " + tostr(m.lastPosition))
            m.playState = "stopped"
            m.UpdateNowPlaying()
            if m.IsTranscoded then m.StopTranscoding()
			m.ReportPlayback("stop")
			m.progressTimer.Active = false

        else if msg.isFullResult() then
            Debug("MediaPlayer::playVideo::VideoScreenEvent::isFullResult: position -> " + tostr(m.lastPosition))
            m.playState = "stopped"
            m.UpdateNowPlaying()
            if m.IsTranscoded then m.StopTranscoding()
			m.ReportPlayback("stop")
			m.progressTimer.Active = false

        else if msg.GetType() = 31 then
            ' TODO(schuyler): DownloadDuration is completely incomprehensible to me.
            ' It doesn't seem like it could be seconds or milliseconds, and I couldn't
            ' seem to do anything to artificially affect it by tweaking PMS.
            segInfo = msg.GetInfo()
            Debug("Downloaded segment " + tostr(segInfo.Sequence) + " in " + tostr(segInfo.DownloadDuration) + "?s (" + tostr(segInfo.SegSize) + " bytes, buffer is now " + tostr(segInfo.BufferLevel) + "/" + tostr(segInfo.BufferSize))

        else if msg.GetType() = 27 then
            ' This is an HLS Segment Info event. We don't really need to do
            ' anything with it. It includes info like the stream bandwidth,
            ' sequence, URL, and start time.
        else
            Debug("Unknown event: " + tostr(msg.GetType()) + " msg: " + tostr(msg.GetMessage()))
        end if
    end if

    return handled
End Function

Sub videoPlayerReportPlayback(action as String)

	m.progressTimer.Mark()

	isPaused = false

	if m.playState = "paused" then isPaused = true
	
	position = m.lastPosition
	
	if m.IsTranscoded and m.PlayOptions.playstart <> invalid then position = position + m.PlayOptions.playstart

	reportPlayback(m.videoItem.Id, action, m.playMethod, isPaused, m.canSeek, position, m.videoItem.StreamInfo.MediaSource.Id, m.videoItem.StreamInfo.AudioStreamIndex, m.videoItem.StreamInfo.SubtitleStreamIndex)
End Sub

Sub videoPlayerPause()
    if m.Screen <> invalid then
        m.Screen.Pause()
    end if
End Sub

Sub videoPlayerResume()
    if m.Screen <> invalid then
        m.Screen.Resume()
    end if
End Sub

Sub videoPlayerNext()
End Sub

Sub videoPlayerPrev()
End Sub

Sub videoPlayerStop()
    if m.Screen <> invalid then
        m.Screen.Close()
    end if
End Sub

Sub videoPlayerSeek(offset, relative=false)

    if m.Screen <> invalid then

        if relative then
            offset = offset + m.lastPosition
            if offset < 0 then offset = 0
        end if

        if m.playState = "paused" then
            m.Screen.Resume()
            m.Screen.Seek(offset)
        else
            m.Screen.Seek(offset)
        end if
    end if

End Sub

Sub videoPlayerStartTranscodeSessionRequest()

    if m.IsTranscoded then

        context = CreateObject("roAssociativeArray")
        context.requestType = "transcode"

		request = HttpRequest(GetServerBaseUrl() + "/Sessions?deviceId=" + getGlobalVar("rokuUniqueId", "Unknown"))
		request.AddAuthorization()
		request.ContentType("json")

		m.ViewController.StartRequest(request.Http, m, context)

    end if

End Sub

Sub videoPlayerOnUrlEvent(msg, requestContext)

    if requestContext.requestType = "transcode" then
        if msg.GetResponseCode() = 200 then

			response = normalizeJson(msg.GetString())

			sessions     = ParseJSON(response)

			DisplayTranscodingInfo(m.Screen, m.videoItem, sessions)
		end if
    end if

End Sub

Sub DisplayTranscodingInfo(screen, item, sessions)

	for each i in sessions
		
		if i.TranscodingInfo <> invalid then

			transcodingInfo = i.TranscodingInfo

			item.ReleaseDate = item.OrigReleaseDate + "   Transcoded"

			if transcodingInfo.Width <> invalid or transcodingInfo.Height <> invalid or transcodingInfo.AudioChannels <> invalid then

				item.ReleaseDate = item.ReleaseDate + " ("

				if transcodingInfo.Width <> invalid and transcodingInfo.Height <> invalid then  item.ReleaseDate = item.ReleaseDate + tostr(transcodingInfo.Width) + "x" + tostr(transcodingInfo.Height)
				if transcodingInfo.AudioChannels <> invalid then item.ReleaseDate = item.ReleaseDate + " " + tostr(transcodingInfo.AudioChannels) + "ch"
				item.ReleaseDate = item.ReleaseDate + ")"
			end if

			item.ReleaseDate = item.ReleaseDate + chr(10)

			item.length = tostr(item.Length)

			if transcodingInfo.VideoCodec <> invalid then item.ReleaseDate = item.ReleaseDate + "    video: " + tostr(transcodingInfo.VideoCodec)
			if transcodingInfo.AudioCodec <> invalid then item.ReleaseDate = item.ReleaseDate + "    audio: " + tostr(transcodingInfo.AudioCodec)

			screen.SetContent(item)

			exit for
		end if

	end for

End Sub

Sub videoPlayerOnTimerExpired(timer)
    
	if timer.Name = "timeline"
        m.UpdateNowPlaying(true)
    end if

End Sub

Sub videoPlayerUpdateNowPlaying(force=false)

    ' Avoid duplicates
    if m.playState = m.lastTimelineState AND NOT force then return

    m.lastTimelineState = m.playState
    m.timelineTimer.Mark()

    NowPlayingManager().UpdatePlaybackState("video", m.Item, m.playState, m.lastPosition)
End Sub

Function videoPlayerConstructVideoItem(item, options) as Object

	item = GetFullItemMetadata(item, true, options)

    'if mediaItem <> invalid then videoItem.Duration = mediaItem.duration ' set duration - used for EndTime/TimeLeft on HUD  - ljunkie

    if item.ReleaseDate = invalid then  item.ReleaseDate = "" ' we never want to display invalid
    item.OrigReleaseDate = item.ReleaseDate

	releaseDate = item.ReleaseDate
	serverStreamInfo = item.StreamInfo

	if serverStreamInfo.IsDirectStream then

       audioCh = ""
	   audioStream = serverStreamInfo.AudioStream

       if audioStream <> invalid and audioStream.Channels <> invalid then
           if (audioStream.Channels = 6) then
               audioCh = "5.1"
           else
              audioCh = tostr(audioStream.Channels) + "ch"
           end if
       end if

	   audioCodec = ""

	   if audioStream <> invalid then
		   if (tostr(audioStream.Codec) = "dca") then
       			audioCodec = "DTS"
		   else
       			audioCodec = tostr(audioStream.Codec)
		   end if
	   end if

	   resolution = ""
	   if serverStreamInfo.VideoStream <> invalid and serverStreamInfo.VideoStream.Width <> invalid then resolution = tostr(serverStreamInfo.VideoStream.Width) + "p "

        item.ReleaseDate = releaseDate + "   Direct Play (" + resolution + audioCh + " " + audioCodec + " " + tostr(item.StreamFormat) + ")"
	else

        item.ReleaseDate = releaseDate + "   Transcoded"
	end if

	return item

End Function

Sub videoPlayerStopTranscoding()

	Debug ("Sending message to server to stop transcoding")

    ' URL
    url = GetServerBaseUrl() + "/Videos/ActiveEncodings"

    ' Prepare Request
    request = HttpRequest(url)
    request.AddAuthorization()
    request.AddParam("DeviceId", getGlobalVar("rokuUniqueId", "Unknown"))
    request.SetRequest("DELETE")

    ' Execute Request
    response = request.PostFromStringWithTimeout("", 5)

    if response = invalid
        Debug("Error stopping server transcoding")
    end if

End Sub