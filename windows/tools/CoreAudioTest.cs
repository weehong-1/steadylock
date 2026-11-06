// Test-only Core Audio helper used by Set-MasterVolume.ps1 and the Windows Sandbox test.
// Reads and writes the default render endpoint's master volume and mute through IAudioEndpointVolume,
// the same API any script or app would use. Compiles under Windows PowerShell 5.1 and PowerShell 7.
using System;
using System.Runtime.InteropServices;

namespace SteadyVolumeTest {
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out uint count);
        int SetMasterVolumeLevel(float levelDb, ref Guid context);
        int SetMasterVolumeLevelScalar(float level, ref Guid context);
        int GetMasterVolumeLevel(out float levelDb);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid context);
        int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
        int GetChannelVolumeLevel(uint channel, out float levelDb);
        int GetChannelVolumeLevelScalar(uint channel, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        int OpenPropertyStore(int access, out IntPtr store);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out uint count);
        int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public static class CoreAudio {
        static IAudioEndpointVolume Activate(IMMDevice device) {
            var iid = typeof(IAudioEndpointVolume).GUID;
            object instance;
            Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out instance));
            return (IAudioEndpointVolume)instance;
        }

        static IAudioEndpointVolume Endpoint() {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out device));
            return Activate(device);
        }

        /// <summary>
        /// READ-ONLY. One line per active output device: "id|volume scalar (4 dp)|muted".
        /// Used to prove a test run left every device's volume and mute exactly as they were.
        /// </summary>
        public static string[] SnapshotAllOutputs() {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDeviceCollection devices;
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(0 /* eRender */, 1 /* DEVICE_STATE_ACTIVE */, out devices));
            uint count;
            Marshal.ThrowExceptionForHR(devices.GetCount(out count));
            var result = new string[count];
            for (uint i = 0; i < count; i++) {
                IMMDevice device;
                Marshal.ThrowExceptionForHR(devices.Item(i, out device));
                string id;
                Marshal.ThrowExceptionForHR(device.GetId(out id));
                var volume = Activate(device);
                float level;
                bool mute;
                Marshal.ThrowExceptionForHR(volume.GetMasterVolumeLevelScalar(out level));
                Marshal.ThrowExceptionForHR(volume.GetMute(out mute));
                result[i] = id + "|" + level.ToString("F4",System.Globalization.CultureInfo.InvariantCulture) + "|" + mute;
            }
            Array.Sort(result, StringComparer.Ordinal);
            return result;
        }

        public static bool HasDefaultOutput() {
            try { Endpoint(); return true; } catch (COMException) { return false; }
        }

        public static int Get() {
            float level;
            Marshal.ThrowExceptionForHR(Endpoint().GetMasterVolumeLevelScalar(out level));
            return (int)Math.Round(level * 100, MidpointRounding.AwayFromZero);
        }

        public static void Set(int percent) {
            var context = Guid.Empty;
            Marshal.ThrowExceptionForHR(Endpoint().SetMasterVolumeLevelScalar(percent / 100f, ref context));
        }

        public static bool GetMute() {
            bool mute;
            Marshal.ThrowExceptionForHR(Endpoint().GetMute(out mute));
            return mute;
        }

        public static void SetMute(bool mute) {
            var context = Guid.Empty;
            Marshal.ThrowExceptionForHR(Endpoint().SetMute(mute, ref context));
        }
    }
}
