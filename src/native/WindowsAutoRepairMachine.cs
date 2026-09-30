using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

namespace Tqr
{
    // Production boundary: no arbitrary service/executable, PATH fallback, shell,
    // peer probe, adapter reset, sign-in command, or implicit elevation.
    public sealed class WindowsAutoRepairMachine : IAutoRepairMachine
    {
        private readonly string directory, environment;
        private readonly int session;
        private string lastLocalIp = "", lastVersion = "";
        public string LastLocalIp { get { return lastLocalIp; } }
        public string LastVersion { get { return lastVersion; } }
        public WindowsAutoRepairMachine()
        {
            session=Process.GetCurrentProcess().SessionId;
            directory=FindInstallation();
            environment=NetworkStamp();
        }
        public DateTime UtcNow { get { return DateTime.UtcNow; } }
        public bool CanContinue
        {
            get
            {
                try { return !Environment.HasShutdownStarted && GetSystemMetrics(0x2000)==0 &&
                    session>0 && Process.GetCurrentProcess().SessionId==session && environment!=null && environment==NetworkStamp(); }
                catch { return false; }
            }
        }
        public bool CanMutate
        {
            get
            {
                try { return CanContinue && directory!=null && RegisteredBinaryMatches(directory) &&
                    new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
                catch { return false; }
            }
        }
        private static string NetworkStamp()
        {
            // Every non-Tailscale interface contributes only to an in-memory
            // continuity stamp. A Wi-Fi/VPN/adapter transition invalidates this
            // machine instance so a stale repair cannot continue across a network
            // change. No vendor is interpreted and no adapter, route or DNS state
            // is changed or persisted here.
            try
            {
                List<string> parts=new List<string>();
                foreach(NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if(nic.Description.IndexOf("Tailscale",StringComparison.OrdinalIgnoreCase)>=0) continue;
                    List<string> ips=new List<string>();
                    foreach(UnicastIPAddressInformation ip in nic.GetIPProperties().UnicastAddresses) ips.Add(ip.Address.ToString());
                    ips.Sort(StringComparer.Ordinal);
                    parts.Add(nic.Id+":"+nic.OperationalStatus+":"+String.Join(";",ips.ToArray()));
                }
                parts.Sort(StringComparer.Ordinal);
                return String.Join("|",parts.ToArray()); // Comparison only in memory.
            }
            catch { return null; }
        }
        private static bool SafeFile(string path)
        {
            try { AutoRepairRecords.CheckPath(path); return File.Exists(path); }
            catch { return false; }
        }
        private static string FindInstallation()
        {
            foreach(Environment.SpecialFolder folder in new[] { Environment.SpecialFolder.ProgramFiles,Environment.SpecialFolder.ProgramFilesX86 })
            {
                string parent=Environment.GetFolderPath(folder);
                if(String.IsNullOrEmpty(parent)) continue;
                string dir=Path.Combine(parent,"Tailscale");
                if(SafeFile(Path.Combine(dir,"tailscale.exe")) && SafeFile(Path.Combine(dir,"tailscale-ipn.exe")) && RegisteredBinaryMatches(dir)) return dir;
            }
            return null;
        }
        private static bool RegisteredBinaryMatches(string dir)
        {
            try
            {
                using(RegistryKey key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\Tailscale",false))
                {
                    if(key==null) return false;
                    string command=Convert.ToString(key.GetValue("ImagePath",null,RegistryValueOptions.DoNotExpandEnvironmentNames));
                    Match m=Regex.Match(command ?? "", "^\\s*(?:\"(?<p>[^\"]+\\.exe)\"|(?<p>[^\"]+?\\.exe))(?:\\s|$)",RegexOptions.IgnoreCase);
                    string expected=Path.Combine(dir,"tailscaled.exe");
                    return m.Success && String.Equals(m.Groups["p"].Value,expected,StringComparison.OrdinalIgnoreCase) && SafeFile(expected);
                }
            }
            catch { return false; }
        }
        private string ClientState()
        {
            bool uncertain=false,found=false;
            foreach(Process process in Process.GetProcessesByName("tailscale-ipn"))
            {
                using(process)
                {
                    try
                    {
                        if(process.SessionId!=session) continue;
                        if(directory==null) { uncertain=true;continue; }
                        if(String.Equals(process.MainModule.FileName,Path.Combine(directory,"tailscale-ipn.exe"),StringComparison.OrdinalIgnoreCase)) found=true;
                        else uncertain=true;
                    }
                    catch { uncertain=true; }
                }
            }
            return found?"Running":uncertain?"Unknown":"Closed";
        }
        public AutoHealth Observe()
        {
            AutoHealth h=new AutoHealth();
            lastLocalIp = lastVersion = "";
            try
            {
                using(RegistryKey key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\Tailscale",false))
                {
                    if(key==null) { h.Service="Missing";return h; }
                    object start=key.GetValue("Start");
                    if(start is int) h.Startup=(int)start==2?"Automatic":(int)start==3?"Manual":(int)start==4?"Disabled":"Unknown";
                }
                using(ServiceController service=new ServiceController("Tailscale"))
                { h.Service=service.Status==ServiceControllerStatus.Running?"Running":service.Status==ServiceControllerStatus.Stopped?"Stopped":"Unknown"; }
                h.Client=ClientState();
                if(h.Service=="Running" && directory!=null && RegisteredBinaryMatches(directory))
                {
                    AutoBackendObservation local=AutoRepairLocalStatus.Read(Path.Combine(directory,"tailscale.exe"),3000);
                    h.Backend=local.Backend;
                    lastLocalIp=local.LocalIp;
                    lastVersion=local.Version;
                }
            }
            catch { }
            return h;
        }
        public bool OpenClient(Action authorize)
        {
            if(!CanMutate || ClientState()!="Closed") return false;
            string path=Path.Combine(directory,"tailscale-ipn.exe");
            if(!SafeFile(path)) return false;
            authorize(); // Latest preference, lease and intent immediately before launch.
            using(Process p=Process.Start(new ProcessStartInfo(path) { UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=directory }))
            { if(p==null) return false; }
            for(int i=0;i<20 && CanContinue;i++) { if(ClientState()=="Running") return true;Thread.Sleep(250); }
            return false;
        }
        public bool StartService(Action authorize)
        {
            if(!CanMutate) return false;
            AutoHealth h=Observe();
            if(!CanMutate || h.Service!="Stopped" || (h.Startup!="Automatic" && h.Startup!="Manual")) return false;
            using(ServiceController service=new ServiceController("Tailscale"))
            { authorize();service.Start();service.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(10));return true; }
        }
        public bool StopService(Action authorize)
        {
            if(!CanMutate || !NetworkInterface.GetIsNetworkAvailable()) return false;
            AutoHealth h=Observe();
            if(!CanMutate || h.Service!="Running" || h.Startup=="Disabled" || (h.Backend!="Starting" && h.Backend!="NoState")) return false;
            IntPtr scm=OpenSCManager(null,null,1), service=IntPtr.Zero;
            if(scm==IntPtr.Zero) return false;
            try
            {
                service=OpenService(scm,"Tailscale",0x20);
                if(service==IntPtr.Zero) return false;
                ServiceStatus status;
                authorize();
                // SCM refuses running dependencies; never stop another service.
                if(!ControlService(service,1,out status)) return false;
                using(ServiceController controller=new ServiceController("Tailscale"))
                { controller.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(10));return true; }
            }
            finally { if(service!=IntPtr.Zero) CloseServiceHandle(service);CloseServiceHandle(scm); }
        }
        public void Pause() { Thread.Sleep(500); }
        [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint type,state,controls,win32,service,checkpoint,wait; }
        [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr OpenSCManager(string machine,string database,uint access);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr OpenService(IntPtr manager,string name,uint access);
        [DllImport("advapi32.dll",SetLastError=true)] private static extern bool ControlService(IntPtr service,uint control,out ServiceStatus status);
        [DllImport("advapi32.dll")] private static extern bool CloseServiceHandle(IntPtr handle);
    }
}