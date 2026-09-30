using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Tailscale Quick Repair")]
[assembly: System.Reflection.AssemblyProduct("Tailscale Quick Repair")]
[assembly: System.Reflection.AssemblyVersion("3.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("3.0.0.0")]

internal static class NativeHost
{
    private const string AppUserModelId = "TailscaleQuickRepair.Desktop";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            try
            {
                SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
            }
            catch
            {
            }

            if (HasSwitch(args, "--self-test-host"))
            {
                return SelfTest();
            }

            string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDirectory, "Tailscale-Repair-UI.ps1");

            if (!File.Exists(scriptPath))
            {
                MessageBox.Show(
                    "The Quick Repair UI component is missing.\r\n\r\n" + scriptPath,
                    "Tailscale Quick Repair",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return 2;
            }

            bool startInTray = HasSwitch(args, "--start-in-tray");
            string script = File.ReadAllText(scriptPath, Encoding.UTF8);

            InitialSessionState initial = InitialSessionState.CreateDefault();

            using (Runspace runspace = RunspaceFactory.CreateRunspace(initial))
            {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();

                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    powershell.AddScript(script, false);

                    if (startInTray)
                    {
                        powershell.AddParameter("StartInTray", true);
                    }

                    Collection<PSObject> ignored = null;
                    Exception invokeFailure = null;

                    try
                    {
                        ignored = powershell.Invoke();
                    }
                    catch (Exception ex)
                    {
                        invokeFailure = ex;
                    }

                    bool uiStartedSuccessfully = GetSessionBool(runspace, "TqrUiStartedSuccessfully");
                    bool uiClosedNormally = GetSessionBool(runspace, "TqrUiClosedNormally");
                    bool shutdownRequested = GetSessionBool(runspace, "TqrUiShutdownRequested");

                    if (invokeFailure != null && !uiStartedSuccessfully && !shutdownRequested && !uiClosedNormally)
                    {
                        throw invokeFailure;
                    }

                    if (powershell.HadErrors && !uiStartedSuccessfully && !shutdownRequested && !uiClosedNormally)
                    {
                        StringBuilder message = new StringBuilder();

                        foreach (ErrorRecord error in powershell.Streams.Error)
                        {
                            if (message.Length > 0)
                            {
                                message.AppendLine();
                            }

                            message.Append(error.ToString());
                        }

                        MessageBox.Show(
                            "Quick Repair could not start.\r\n\r\n" + message.ToString(),
                            "Tailscale Quick Repair",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Error
                        );
                        return 3;
                    }
                }
            }

            return 0;
        }
        catch (Exception ex)
        {
            try
            {
                MessageBox.Show(
                    "Quick Repair could not start.\r\n\r\n" + ex.Message,
                    "Tailscale Quick Repair",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
            catch
            {
            }

            return 10;
        }
    }

    private static bool GetSessionBool(Runspace runspace, string name)
    {
        try
        {
            object marker = runspace.SessionStateProxy.GetVariable(name);
            return marker is bool && (bool)marker;
        }
        catch
        {
            return false;
        }
    }

    private static int SelfTest()
    {
        try
        {
            InitialSessionState initial = InitialSessionState.CreateDefault();

            using (Runspace runspace = RunspaceFactory.CreateRunspace(initial))
            {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();

                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    powershell.AddScript("$PSVersionTable.PSVersion.ToString()", false);
                    Collection<PSObject> result = powershell.Invoke();

                    if (powershell.HadErrors || result == null || result.Count == 0)
                    {
                        return 11;
                    }
                }
            }

            return 0;
        }
        catch
        {
            return 12;
        }
    }

    private static bool HasSwitch(string[] args, string name)
    {
        if (args == null)
        {
            return false;
        }

        foreach (string arg in args)
        {
            if (String.Equals(arg, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
