using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

// Test-only native boundaries. Never compiled into a product package.
namespace TqrPermissionLab
{
    public sealed class AccessResult { public bool Allowed; public int Error; }
    public sealed class RestrictedProcess : IDisposable
    {
        private Process process;
        private IntPtr desktop,station;
        internal RestrictedProcess(Process p,IntPtr d,IntPtr s){process=p;desktop=d;station=s;}
        public bool HasExited {get{return process.HasExited;}}
        public int ExitCode {get{return process.ExitCode;}}
        public bool WaitForExit(int milliseconds){return process.WaitForExit(milliseconds);}
        public void Kill(){process.Kill();}
        public void Dispose()
        {
            if(process!=null){process.Dispose();process=null;}
            bool ok=true;
            if(desktop!=IntPtr.Zero){ok=Probe.CloseDesktop(desktop);desktop=IntPtr.Zero;}
            if(station!=IntPtr.Zero){ok=Probe.CloseWindowStation(station) && ok;station=IntPtr.Zero;}
            if(!ok) throw new Win32Exception();
        }
    }
    public static class Probe
    {
        public static AccessResult Open(string path,uint desired,bool directory)
        {
            IntPtr h=CreateFile(path,desired,7,IntPtr.Zero,3,directory?0x02000000u:0u,IntPtr.Zero);
            if(h==new IntPtr(-1)) return new AccessResult {Allowed=false,Error=Marshal.GetLastWin32Error()};
            CloseHandle(h);
            return new AccessResult {Allowed=true,Error=0}; // Open only: no content/ACL changes.
        }
        public static int Integrity()
        {
            IntPtr token=IntPtr.Zero,data=IntPtr.Zero;
            try
            {
                if(!OpenProcessToken(Process.GetCurrentProcess().Handle,8,out token)) throw new Win32Exception();
                int length;GetTokenInformation(token,25,IntPtr.Zero,0,out length);
                data=Marshal.AllocHGlobal(length);
                if(!GetTokenInformation(token,25,data,length,out length)) throw new Win32Exception();
                string sid=new SecurityIdentifier(Marshal.ReadIntPtr(data)).Value;
                return Int32.Parse(sid.Substring(sid.LastIndexOf('-')+1));
            }
            finally {if(data!=IntPtr.Zero) Marshal.FreeHGlobal(data);if(token!=IntPtr.Zero) CloseHandle(token);}
        }
        public static int PrivilegeCount()
        {
            IntPtr token=IntPtr.Zero,data=IntPtr.Zero;
            try
            {
                if(!OpenProcessToken(Process.GetCurrentProcess().Handle,8,out token)) throw new Win32Exception();
                int length;GetTokenInformation(token,3,IntPtr.Zero,0,out length);
                data=Marshal.AllocHGlobal(length);
                if(!GetTokenInformation(token,3,data,length,out length)) throw new Win32Exception();
                return Marshal.ReadInt32(data);
            }
            finally {if(data!=IntPtr.Zero) Marshal.FreeHGlobal(data);if(token!=IntPtr.Zero) CloseHandle(token);}
        }
        public static RestrictedProcess StartRestricted(string executable,string arguments,string directory)
        {
            IntPtr parent=IntPtr.Zero,child=IntPtr.Zero,admin=IntPtr.Zero,medium=IntPtr.Zero;
            IntPtr security=IntPtr.Zero,station=IntPtr.Zero,desktop=IntPtr.Zero,userSid=IntPtr.Zero;
            IntPtr original=GetProcessWindowStation();bool transferred=false;
            ProcessInfo pi=new ProcessInfo();
            try
            {
                if(!OpenProcessToken(Process.GetCurrentProcess().Handle,0xF01FF,out parent)) throw new Win32Exception();
                if(!ConvertStringSidToSid("S-1-5-32-544",out admin) || !ConvertStringSidToSid("S-1-16-8192",out medium)) throw new Win32Exception();
                SidAttributes[] deny={new SidAttributes {Sid=admin,Attributes=0}};
                if(!CreateRestrictedToken(parent,1,1,deny,0,IntPtr.Zero,0,IntPtr.Zero,out child)) throw new Win32Exception();
                SidAttributes label=new SidAttributes {Sid=medium,Attributes=0x20};
                if(!SetTokenInformation(child,25,ref label,Marshal.SizeOf(typeof(SidAttributes))+(int)GetLengthSid(medium))) throw new Win32Exception();
                // Hosted-runner desktops need not allow the restricted token.
                // Create private USER objects; never relax the existing desktop,
                // product files, tasks, token integrity or administrator restrictions.
                string sid=WindowsIdentity.GetCurrent().User.Value;
                string sddl="D:P(A;;GA;;;SY)(A;;GA;;;"+sid+")S:(ML;;NW;;;ME)";
                uint bytes;
                if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out security,out bytes)) throw new Win32Exception();
                // A restricted child must own/read its own new kernel objects.
                // This changes only defaults on the newly created test token; it
                // grants no access to any existing product file or scheduled task.
                bool present,defaulted;IntPtr dacl;
                if(!GetSecurityDescriptorDacl(security,out present,out dacl,out defaulted) || !present || dacl==IntPtr.Zero) throw new Win32Exception();
                if(!SetTokenPointer(child,6,ref dacl,IntPtr.Size) || !ConvertStringSidToSid(sid,out userSid) ||
                    !SetTokenPointer(child,4,ref userSid,IntPtr.Size)) throw new Win32Exception();
                SecurityAttributes sa=new SecurityAttributes {Length=Marshal.SizeOf(typeof(SecurityAttributes)),Descriptor=security,Inherit=false};
                string name="TqrPermissionStation"+Guid.NewGuid().ToString("N");
                station=CreateWindowStation(name,0,0x10000000,ref sa);
                if(station==IntPtr.Zero || original==IntPtr.Zero) throw new Win32Exception();
                if(!SetProcessWindowStation(station)) throw new Win32Exception();
                try
                {
                    desktop=CreateDesktop("Default",null,IntPtr.Zero,0,0x10000000,ref sa);
                    if(desktop==IntPtr.Zero) throw new Win32Exception();
                }
                finally {if(!SetProcessWindowStation(original)) throw new Win32Exception();}
                StartupInfo si=new StartupInfo();si.cb=Marshal.SizeOf(typeof(StartupInfo));si.desktop=name+"\\Default";
                if(!CreateProcessAsUser(child,executable,new StringBuilder("\""+executable+"\" "+arguments),ref sa,ref sa,false,0x08000000,IntPtr.Zero,directory,ref si,out pi)) throw new Win32Exception();
                Process process=Process.GetProcessById((int)pi.pid);
                IntPtr retained=process.Handle; // Retain even a fast startup-failure exit status.
                RestrictedProcess result=new RestrictedProcess(process,desktop,station);transferred=true;
                return result;
            }
            finally
            {
                if(pi.thread!=IntPtr.Zero) CloseHandle(pi.thread);if(pi.process!=IntPtr.Zero) CloseHandle(pi.process);
                if(child!=IntPtr.Zero) CloseHandle(child);if(parent!=IntPtr.Zero) CloseHandle(parent);
                if(admin!=IntPtr.Zero) LocalFree(admin);if(medium!=IntPtr.Zero) LocalFree(medium);if(security!=IntPtr.Zero) LocalFree(security);if(userSid!=IntPtr.Zero) LocalFree(userSid);
                if(!transferred){if(desktop!=IntPtr.Zero) CloseDesktop(desktop);if(station!=IntPtr.Zero) CloseWindowStation(station);}
            }
        }
        [StructLayout(LayoutKind.Sequential)] private struct SidAttributes {public IntPtr Sid;public uint Attributes;}
        [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes {public int Length;public IntPtr Descriptor;[MarshalAs(UnmanagedType.Bool)] public bool Inherit;}
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct StartupInfo
        {
            public int cb;public string reserved,desktop,title;public uint x,y,xSize,ySize,xChars,yChars,fill,flags;
            public ushort show,reservedSize;public IntPtr reservedPointer,input,output,error;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo {public IntPtr process,thread;public uint pid,tid;}
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateFileW")] private static extern IntPtr CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("advapi32.dll",SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] private static extern bool GetTokenInformation(IntPtr token,int info,IntPtr data,int length,out int required);
        [DllImport("advapi32.dll",SetLastError=true)] private static extern bool CreateRestrictedToken(IntPtr existing,uint flags,uint count,SidAttributes[] disabled,uint deleted,IntPtr privileges,uint restricted,IntPtr sids,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] private static extern bool SetTokenInformation(IntPtr token,int info,ref SidAttributes data,int length);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="ConvertStringSidToSidW")] private static extern bool ConvertStringSidToSid(string text,out IntPtr sid);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="ConvertStringSecurityDescriptorToSecurityDescriptorW")] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr sd,out uint size);
        [DllImport("advapi32.dll",SetLastError=true)] private static extern bool GetSecurityDescriptorDacl(IntPtr descriptor,out bool present,out IntPtr dacl,out bool defaulted);
        [DllImport("advapi32.dll",SetLastError=true,EntryPoint="SetTokenInformation")] private static extern bool SetTokenPointer(IntPtr token,int info,ref IntPtr data,int length);
        [DllImport("advapi32.dll")] private static extern uint GetLengthSid(IntPtr sid);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateProcessAsUserW")] private static extern bool CreateProcessAsUser(IntPtr token,string app,StringBuilder command,ref SecurityAttributes pa,ref SecurityAttributes ta,bool inherit,uint flags,IntPtr env,string directory,ref StartupInfo startup,out ProcessInfo info);
        [DllImport("user32.dll",SetLastError=true)] private static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll",SetLastError=true)] private static extern bool SetProcessWindowStation(IntPtr station);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateWindowStationW")] private static extern IntPtr CreateWindowStation(string name,uint flags,uint access,ref SecurityAttributes security);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="CreateDesktopW")] private static extern IntPtr CreateDesktop(string name,string device,IntPtr mode,uint flags,uint access,ref SecurityAttributes security);
        [DllImport("user32.dll",SetLastError=true)] internal static extern bool CloseWindowStation(IntPtr station);
        [DllImport("user32.dll",SetLastError=true)] internal static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr h);
    }
}
