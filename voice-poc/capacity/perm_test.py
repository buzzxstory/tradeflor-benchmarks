"""M6: server-side source permission. Token grants canPublish with canPublishSources=["microphone"] only.
Publishes (1) audio as microphone, (2) video as camera, (3) video as screen share, (4) a VIDEO track that claims
source=microphone, then asks the server (RoomService.ListParticipants) which tracks it actually accepted."""
import asyncio
import json
import sys

from livekit import api, rtc

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:7880"
HTTP = URL.replace("ws://", "http://")
ROOM = "perm-test"
TYPES = {0: "AUDIO", 1: "VIDEO", 2: "DATA"}
SOURCES = {0: "UNKNOWN", 1: "CAMERA", 2: "MICROPHONE", 3: "SCREEN_SHARE", 4: "SCREEN_SHARE_AUDIO"}


async def feed_audio(src):
    frame = rtc.AudioFrame.create(48000, 1, 480)
    while True:
        await src.capture_frame(frame)
        await asyncio.sleep(0.01)


async def feed_video(src):
    frame = rtc.VideoFrame(320, 240, rtc.VideoBufferType.RGBA, bytearray(320 * 240 * 4))
    while True:
        src.capture_frame(frame)
        await asyncio.sleep(1 / 15)


async def try_publish(room, track, source, label, res):
    try:
        pub = await asyncio.wait_for(
            room.local_participant.publish_track(track, rtc.TrackPublishOptions(source=source)), 15)
        res[label] = {"client_result": "PUBLISHED", "sid": pub.sid}
    except Exception as e:  # noqa: BLE001
        res[label] = {"client_result": "REJECTED/FAILED", "error": f"{type(e).__name__}: {e}"}


async def main():
    res = {}
    grants = api.VideoGrants(room_join=True, room=ROOM, can_publish=True, can_subscribe=True,
                             can_publish_sources=["microphone"])
    token = api.AccessToken("devkey", "secret").with_identity("perm-client").with_grants(grants).to_jwt()
    room = rtc.Room()
    await room.connect(URL, token)
    res["connected"] = True
    tasks = []

    asrc = rtc.AudioSource(48000, 1)
    tasks.append(asyncio.create_task(feed_audio(asrc)))
    await try_publish(room, rtc.LocalAudioTrack.create_audio_track("mic", asrc),
                      rtc.TrackSource.SOURCE_MICROPHONE, "audio_as_microphone", res)

    for label, source in [("video_as_camera", rtc.TrackSource.SOURCE_CAMERA),
                          ("video_as_screenshare", rtc.TrackSource.SOURCE_SCREENSHARE),
                          ("video_claiming_microphone_source", rtc.TrackSource.SOURCE_MICROPHONE)]:
        vsrc = rtc.VideoSource(320, 240)
        tasks.append(asyncio.create_task(feed_video(vsrc)))
        await try_publish(room, rtc.LocalVideoTrack.create_video_track(label, vsrc), source, label, res)

    await asyncio.sleep(3)
    lkapi = api.LiveKitAPI(HTTP, "devkey", "secret")
    ps = await lkapi.room.list_participants(api.ListParticipantsRequest(room=ROOM))
    res["server_view"] = [
        {"identity": p.identity,
         "permission_sources": [SOURCES.get(int(x), x) for x in p.permission.can_publish_sources],
         "tracks": [{"name": t.name, "type": TYPES.get(int(t.type), t.type), "source": SOURCES.get(int(t.source), t.source),
                     "sid": t.sid} for t in p.tracks]}
        for p in ps.participants]
    await lkapi.aclose()
    for t in tasks:
        t.cancel()
    await room.disconnect()
    print(json.dumps(res, indent=2))


asyncio.run(main())
