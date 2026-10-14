import NativeTrackPlayer from '../NativeTrackPlayer';
import { play } from '../trackPlayer';

jest.mock('../NativeTrackPlayer', () => ({
  __esModule: true,
  default: {
    play: jest.fn(),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
  },
}));

const mockedPlay = jest.mocked(NativeTrackPlayer.play);

beforeEach(() => {
  jest.clearAllMocks();
  mockedPlay.mockResolvedValue(undefined);
});

it('treats the existing no-argument public Play API as a user request', async () => {
  await play();

  expect(mockedPlay.mock.calls).toEqual([[true]]);
});

it.each([true, false])(
  'forwards userInitiated=%s through the native bridge',
  async (userInitiated) => {
    await play({ userInitiated });

    expect(mockedPlay.mock.calls).toEqual([[userInitiated]]);
  },
);

it('propagates an activation failure and admits a later public Play retry', async () => {
  const error = { code: 'audio_session_activation_failed', message: 'Audio session is busy' };
  mockedPlay.mockRejectedValueOnce(error);

  await expect(play()).rejects.toEqual(error);
  await play();

  expect(mockedPlay.mock.calls).toEqual([[true], [true]]);
});
