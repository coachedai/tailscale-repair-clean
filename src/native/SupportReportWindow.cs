using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using Microsoft.Win32;

namespace Tqr
{
    public static class SupportReportWindow
    {
        // Native delegates avoid PowerShell dynamic-scope callbacks outliving
        // their report window. Test substitutes only the external clipboard and
        // Save As picker; the preview selection and SaveNew implementation are real.
        public static Window Create(Window owner, SupportReport withoutHistory, SupportReport withHistory)
        { return Create(owner, withoutHistory, withHistory, delegate(string text) { Clipboard.SetText(text); }, ChooseDestination); }

        public static Window Create(Window owner, SupportReport withoutHistory, SupportReport withHistory,
            Action<string> copy, Func<Window, string> chooseDestination)
        {
            if (owner == null || withoutHistory == null || withHistory == null || copy == null || chooseDestination == null)
                throw new ArgumentException("Support preview unavailable.");
            Window dialog = new Window {
                Title = "Share report", Owner = owner, ShowInTaskbar = false,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Width = Math.Min(760, SystemParameters.WorkArea.Width - 40),
                Height = Math.Min(650, SystemParameters.WorkArea.Height - 40), MinWidth = 480, MinHeight = 390,
                FontFamily = owner.FontFamily, Background = owner.Background
            };
            dialog.Resources.MergedDictionaries.Add(owner.Resources);
            ScrollViewer history = owner.FindName("HistoryPanel") as ScrollViewer;
            if (history != null) dialog.Resources.MergedDictionaries.Add(history.Resources);
            const string markup = @"<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
 xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Margin='24'>
 <Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
 <StackPanel Grid.Row='0'>
  <TextBlock Text='Share report' FontSize='23' FontWeight='SemiBold' Foreground='{DynamicResource Text}'/>
  <TextBlock Text='Names, addresses and raw logs are excluded. Nothing is uploaded.' FontSize='12' Margin='0,7,0,0' TextWrapping='Wrap' Foreground='{DynamicResource Muted}'/>
 </StackPanel>
 <CheckBox x:Name='IncludeHistory' Grid.Row='1' Content='Include recent history' Margin='0,16,0,12' FontSize='12' Foreground='{DynamicResource Value}'
  AutomationProperties.HelpText='Adds up to ten typed events from the last thirty days, without device identifiers.'/>
 <Border Grid.Row='2' CornerRadius='7' BorderBrush='{DynamicResource Border}' BorderThickness='1' Background='{DynamicResource Surface}' Padding='12'>
  <TextBox x:Name='ReportPreview' IsReadOnly='True' IsUndoEnabled='False' TextWrapping='Wrap'
   VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Disabled' BorderThickness='0'
   Background='Transparent' Foreground='{DynamicResource Value}' FontFamily='Consolas' FontSize='11.5'
   AutomationProperties.Name='Privacy-safe report preview'/>
 </Border>
 <TextBlock x:Name='ReportStatus' Grid.Row='3' Text='Snapshot captured when this window opened.' Margin='0,10,0,10' FontSize='11' TextWrapping='Wrap' Foreground='{DynamicResource Muted}'/>
 <DockPanel Grid.Row='4' LastChildFill='False'>
  <Button x:Name='CloseReport' DockPanel.Dock='Left' Content='Close' IsCancel='True' MinWidth='60' Style='{DynamicResource GhostButtonStyle}'/>
  <Button x:Name='CopyReport' DockPanel.Dock='Right' Content='Copy report' Width='120' Height='36' Margin='12,0,0,0' Style='{DynamicResource PrimaryButtonStyle}'/>
  <Button x:Name='SaveReport' DockPanel.Dock='Right' Content='Save .txt' Width='100' Height='36' Style='{DynamicResource SecondaryButtonStyle}'/>
 </DockPanel>
</Grid>";
            Grid grid = (Grid)XamlReader.Parse(markup); dialog.Content = grid;
            CheckBox include = (CheckBox)grid.FindName("IncludeHistory");
            TextBox preview = (TextBox)grid.FindName("ReportPreview");
            TextBlock status = (TextBlock)grid.FindName("ReportStatus");
            Button copyButton = (Button)grid.FindName("CopyReport"), saveButton = (Button)grid.FindName("SaveReport"), close = (Button)grid.FindName("CloseReport");
            SupportReport selected = withoutHistory; bool busy = false, closed = false;
            preview.Text = selected.Text;
            RoutedEventHandler update = delegate {
                if (closed) return;
                selected = include.IsChecked == true ? withHistory : withoutHistory;
                preview.Text = selected.Text; preview.ScrollToHome();
                status.Text = "Review the exact text that will be copied or saved.";
            };
            include.Checked += update; include.Unchecked += update;
            Action<bool> setBusy = delegate(bool value) { busy = value; copyButton.IsEnabled = !value; saveButton.IsEnabled = !value; include.IsEnabled = !value; };
            copyButton.Click += delegate {
                if (busy || closed) return;
                setBusy(true);
                try { copy(selected.Text); status.Text = "Copied. Share only where you intend to send it."; }
                catch { status.Text = "Clipboard unavailable. Nothing was copied; try again or save a file."; }
                finally { if (!closed) setBusy(false); }
            };
            saveButton.Click += delegate {
                if (busy || closed) return;
                setBusy(true);
                try {
                    string destination = chooseDestination(dialog);
                    if (String.IsNullOrEmpty(destination)) { status.Text = "Save cancelled. No file was created."; return; }
                    if (closed) return;
                    selected.SaveNew(destination);
                    status.Text = "Saved locally. The file contains exactly the preview above.";
                }
                catch { status.Text = "Could not save. Choose a new .txt filename in a normal local folder."; }
                finally { if (!closed) setBusy(false); }
            };
            close.Click += delegate { dialog.Close(); };
            dialog.Closed += delegate { closed = true; preview.Clear(); selected = null; };
            return dialog;
        }
        public static string ChooseDestination(Window owner)
        {
            SaveFileDialog picker = new SaveFileDialog {
                Title = "Save a new support report", FileName = "QuickRepair-report-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt",
                DefaultExt = ".txt", Filter = "Text report (*.txt)|*.txt", AddExtension = true,
                CheckPathExists = true, ValidateNames = true, OverwritePrompt = false
            };
            picker.FileOk += delegate(object sender, System.ComponentModel.CancelEventArgs e) {
                if (File.Exists(picker.FileName) || Directory.Exists(picker.FileName)) {
                    e.Cancel = true;
                    MessageBox.Show(owner, "Choose a new filename to keep the existing file unchanged.", "Save report", MessageBoxButton.OK, MessageBoxImage.Information);
                }
            };
            return picker.ShowDialog(owner) == true ? picker.FileName : null;
        }
    }
}
