FreePlayer
---
Swift framework for streaming, playing audio
>The project is based on the project [FreeStreamer](https://github.com/muhku/FreeStreamer)

why?
---
- Pure Swift implementation, no need to mixing Objective-C/C++ in project

Features
---

- [x] CPU-friendly design(4% - 6%)

- [x] Multiple protocols supported: ShoutCast, standard HTTP, local files

- [x] Prepared for tough network conditions: adjustable buffer sizes, stream pre-buffering and restart on failures，restart on not full content streamed when end of stream

- [ ] Metadata support: ShoutCast metadata, IDv2 tags

- [x] Local disk caching: user only needs to stream a file once and after that it can be played from a local cache

- [x] Local disk storing: user can add a folder for local resource loading

- [x] Preloading: playback can start immediately without needing to wait for buffering

- [ ] Record: support recording the stream contents to a file

- [ ] Access the PCM audio samples: as an example, a visualizer is included

- [x] logging to file supported

- [ ] FLAC support
