// Prints the Authenticode check result (WinVerifyTrust) and the signer of each
// file given, one line per file:  0x00000000<TAB>CN="Autodesk, Inc.", O=...
// install.sh compiles it inside the prefix with .NET Framework's csc.exe.
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

class VerifyTrust
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WINTRUST_FILE_INFO { public int cbStruct; public string pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }

    [StructLayout(LayoutKind.Sequential)]
    struct WINTRUST_DATA
    {
        public int cbStruct; public IntPtr pPolicyCallbackData, pSIPClientData;
        public int dwUIChoice, fdwRevocationChecks, dwUnionChoice; public IntPtr pFile;
        public int dwStateAction; public IntPtr hWVTStateData, pwszURLReference;
        public int dwProvFlags, dwUIContext; public IntPtr pSignatureSettings;
    }

    [DllImport("wintrust.dll")]
    static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref WINTRUST_DATA data);

    static int Main(string[] args)
    {
        Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
        foreach (string path in args)
        {
            WINTRUST_FILE_INFO fi = new WINTRUST_FILE_INFO();
            fi.cbStruct = Marshal.SizeOf(typeof(WINTRUST_FILE_INFO));
            fi.pcwszFilePath = path;
            IntPtr pfi = Marshal.AllocHGlobal(fi.cbStruct);
            Marshal.StructureToPtr(fi, pfi, false);
            WINTRUST_DATA d = new WINTRUST_DATA();
            d.cbStruct = Marshal.SizeOf(typeof(WINTRUST_DATA));
            d.dwUIChoice = 2;          // WTD_UI_NONE
            d.fdwRevocationChecks = 0; // WTD_REVOKE_NONE
            d.dwUnionChoice = 1;       // WTD_CHOICE_FILE
            d.pFile = pfi;
            d.dwStateAction = 1;       // WTD_STATEACTION_VERIFY
            int result = WinVerifyTrust(IntPtr.Zero, ref action, ref d);
            d.dwStateAction = 2;       // WTD_STATEACTION_CLOSE
            WinVerifyTrust(IntPtr.Zero, ref action, ref d);
            Marshal.FreeHGlobal(pfi);
            string subject = "";
            try { subject = X509Certificate.CreateFromSignedFile(path).Subject; } catch (Exception) { }
            Console.WriteLine("0x{0:X8}\t{1}", result, subject);
        }
        return 0;
    }
}
