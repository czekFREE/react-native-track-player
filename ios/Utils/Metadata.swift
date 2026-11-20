//
//  Metadata.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 23.06.19.
//  Copyright © 2019 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import SwiftAudioEx

struct Metadata {
    static func update(
        for player: AudioPlayer,
        with metadata: [String: Any],
        urlSession: URLSession = .shared
    ) {
        var ret: [NowPlayingInfoKeyValue] = []
        
        if let title = metadata["title"] as? String {
            ret.append(MediaItemProperty.title(title))
        } else if metadata["title"] is NSNull {
            ret.append(MediaItemProperty.title(nil))
        }
        
        if let artist = metadata["artist"] as? String {
            ret.append(MediaItemProperty.artist(artist))
        } else if metadata["artist"] is NSNull {
            ret.append(MediaItemProperty.artist(nil))
        }
        
        if let album = metadata["album"] as? String {
            ret.append(MediaItemProperty.albumTitle(album))
        } else if metadata["album"] is NSNull {
            ret.append(MediaItemProperty.albumTitle(nil))
        }
        
        if let duration = metadata["duration"] as? Double {
            ret.append(MediaItemProperty.duration(duration))
        } else if metadata["duration"] is NSNull {
            ret.append(MediaItemProperty.duration(nil))
        }
        
        if let elapsedTime = metadata["elapsedTime"] as? Double {
            ret.append(NowPlayingInfoProperty.elapsedPlaybackTime(elapsedTime))
        } else if metadata["elapsedTime"] is NSNull {
            ret.append(NowPlayingInfoProperty.elapsedPlaybackTime(nil))
        }

        if let isLiveStream = metadata["isLiveStream"] as? Bool {
            ret.append(NowPlayingInfoProperty.isLiveStream(isLiveStream))
        } else if metadata["isLiveStream"] is NSNull {
            ret.append(NowPlayingInfoProperty.isLiveStream(nil))
        }
        
        player.nowPlayingInfoController.set(keyValues: ret)

        guard let artwork = metadata["artwork"] else { return }

        guard !(artwork is NSNull), let artworkURL = MediaURL(object: artwork) else {
            player.loadArtwork { $0(nil) }
            return
        }
        if artworkURL.isLocal {
            player.loadArtwork { $0(UIImage(contentsOfFile: artworkURL.value.path)) }
        } else {
            player.loadArtwork(from: artworkURL.value, urlSession: urlSession)
        }
    }
}
