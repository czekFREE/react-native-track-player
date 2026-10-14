export interface PlaybackErrorEvent {
  /** The error code */
  code: string;
  /** The error message */
  message: string;
  /** The active track when a native audio-session error occurred, if available. */
  trackId?: string;
}
