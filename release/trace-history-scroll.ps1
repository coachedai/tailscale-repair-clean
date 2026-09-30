param([Windows.Window]$Window,[Windows.Controls.ScrollViewer]$Viewer,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
Add-Type -ReferencedAssemblies @('WindowsBase','PresentationCore','PresentationFramework','System.Xaml') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
public static class TqrScrollEvidence
{
    public static string[] Capture(Window window, ScrollViewer viewer)
    {
        List<string> trace = new List<string>();
        ScrollChangedEventHandler observer = delegate(object sender, ScrollChangedEventArgs e) {
            trace.Add("Changed: " + viewer.VerticalOffset + " delta=" + e.VerticalChange + " extent=" + viewer.ExtentHeight);
        };
        viewer.ScrollChanged += observer;
        try
        {
            trace.Add("Window: visible=" + window.IsVisible + " loaded=" + window.IsLoaded + " state=" + window.WindowState);
            trace.Add("Same named viewer: " + Object.ReferenceEquals(window.FindName("HistoryPanel"),viewer));
            for (DependencyObject node=viewer; node!=null; node=VisualTreeHelper.GetParent(node))
            {
                FrameworkElement element=node as FrameworkElement;
                if(element!=null) trace.Add("Ancestor " + element.GetType().Name + " " + element.Name + " visibility="+element.Visibility+" loaded="+element.IsLoaded+" visible="+element.IsVisible+" sameWindow="+Object.ReferenceEquals(node,window));
            }
            trace.Add("Before: visible=" + viewer.IsVisible + " loaded=" + viewer.IsLoaded + " enabled=" + viewer.IsEnabled + " offset=" + viewer.VerticalOffset);
            viewer.BringIntoView(); Pump();
            trace.Add("Brought into view: " + viewer.TranslatePoint(new Point(0,0),window));
            viewer.ScrollToEnd(); Pump();
            trace.Add("Native end: " + viewer.VerticalOffset);
            viewer.ScrollToVerticalOffset(120); Pump();
            trace.Add("Native offset120: " + viewer.VerticalOffset);
            viewer.ScrollToTop(); Pump();
            Window control = new Window { Width=340, Height=240, ShowInTaskbar=false, WindowStartupLocation=WindowStartupLocation.Manual, Left=20, Top=20 };
            ScrollViewer stock = new ScrollViewer { VerticalScrollBarVisibility=ScrollBarVisibility.Auto, MaxHeight=170 };
            stock.Content = new TextBlock { Text=String.Join("\n",new string[100]).Replace("\n","entry\n") };
            control.Content=stock;
            control.Show(); Pump();
            try {
                trace.Add("Stock extent: " + stock.ScrollableHeight);
                stock.ScrollToEnd(); Pump();
                trace.Add("Stock end: " + stock.VerticalOffset);
            } finally {control.Close();}
            return trace.ToArray();
        }
        finally {viewer.ScrollChanged -= observer;}
    }
    private static void Pump()
    {
        DispatcherFrame frame = new DispatcherFrame();
        DispatcherTimer timer = new DispatcherTimer(DispatcherPriority.ApplicationIdle);
        timer.Interval = TimeSpan.FromMilliseconds(250);
        timer.Tick += delegate { timer.Stop(); frame.Continue=false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
    }
}
'@
$trace=[TqrScrollEvidence]::Capture($Window,$Viewer)
[IO.File]::WriteAllLines((Join-Path $EvidenceDirectory 'history-scroll-trace.txt'),$trace)
Write-Host ($trace -join '; ')
