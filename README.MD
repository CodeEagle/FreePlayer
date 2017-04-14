FreePlayer
---
Swift framework for streaming, playing audio
>The project is based on the project [FreeStreamer](https://github.com/muhku/FreeStreamer)

why?
---
- Pure Swift implementation, no need to mixing Objective-C/C++ in project

Features
---
- [x] Digest(Tested), Basic(not tested) proxy support

- [x] CPU-friendly design(4% - 6%)

- [x] Multiple protocols supported: ShoutCast, standard HTTP, local files

- [x] Prepared for tough network conditions: adjustable buffer sizes, stream pre-buffering and restart on failures，restart on not full content streamed when end of stream

- [x] Metadata support: ShoutCast metadata, ID3V1, ID3v1.1, ID3v2.2, ID3v2.3, ID3v2.4

- [x] Local disk caching: user only needs to stream a file once and after that it can be played from a local cache

- [x] Local disk storing: user can add a folder for local resource loading

- [x] Preloading: playback can start immediately without needing to wait for buffering

- [x] Record: support recording the stream contents to a file

- [ ] Access the PCM audio samples: as an example, a visualizer is included

- [x] custom logging module and logging into file supported

- [ ] FLAC support

License
---
See [LICENSE](https://github.com/CodeEagle/FreePlayer/blob/master/LICENSE) for the license.
