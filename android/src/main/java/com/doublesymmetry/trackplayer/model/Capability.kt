/* Adapted from KotlinAudio, copyright 2022 Double Symmetry GmbH, Apache-2.0. */
package com.doublesymmetry.trackplayer.model

enum class Capability {
    PLAY,
    PLAY_FROM_ID,
    PLAY_FROM_SEARCH,
    PAUSE,
    STOP,
    SEEK_TO,
    SKIP,
    SKIP_TO_NEXT,
    SKIP_TO_PREVIOUS,
    JUMP_FORWARD,
    JUMP_BACKWARD,
    SET_RATING,
    LIKE,
    DISLIKE,
    BOOKMARK
}
