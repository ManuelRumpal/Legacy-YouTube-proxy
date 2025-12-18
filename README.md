# Legacy-YouTube-proxy
This is a very early concept for a tool that allows a Windows DNS &amp; proxy to relay modern YouTube to long unsupported API v2 players (pre 2015), originally made to work on LG BD player, untested as of 12/18/25.

Note that I'm writing it with the assistance is Microsoft's copilot.

Needed: yt-dlp, ffmpeg, Windows DNS server.

Features and functionality: 

Listening for traffic from target device on port 80 to *.youtube.com, translating requests and fetching metadata and video, conversion via ffmpeg due to the limits of my device and sending by chunks to the player, ideally before it times out trying to get the video.
