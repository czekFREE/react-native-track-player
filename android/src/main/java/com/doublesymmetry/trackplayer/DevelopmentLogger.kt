package com.doublesymmetry.trackplayer

import timber.log.Timber

object DevelopmentLogger {
    fun tag(tag: String) = TaggedDevelopmentLogger(tag)

    fun d(message: String, vararg args: Any?) {
        if (BuildConfig.DEBUG) {
            Timber.d(message, *args)
        }
    }

    fun w(throwable: Throwable, message: String, vararg args: Any?) {
        if (BuildConfig.DEBUG) {
            Timber.w(throwable, message, *args)
        }
    }
}

class TaggedDevelopmentLogger(private val tag: String) {
    fun d(message: String, vararg args: Any?) {
        if (BuildConfig.DEBUG) {
            Timber.tag(tag).d(message, *args)
        }
    }

    fun w(message: String, vararg args: Any?) {
        if (BuildConfig.DEBUG) {
            Timber.tag(tag).w(message, *args)
        }
    }

    fun w(throwable: Throwable, message: String, vararg args: Any?) {
        if (BuildConfig.DEBUG) {
            Timber.tag(tag).w(throwable, message, *args)
        }
    }
}
