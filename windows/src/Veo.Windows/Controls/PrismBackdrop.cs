using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Veo_Windows.Controls;
public sealed class PrismBackdrop : Grid
{
    MediaPlayer? player;
    readonly MediaPlayerElement movie = new() {Stretch=Stretch.UniformToFill,AreTransportControlsEnabled=false};
    public PrismBackdrop()
    {
        IsHitTestVisible=false;
        Children.Add(new Image {Source=new BitmapImage(new Uri("ms-appx:///Assets/VeoPrism.jpg")),Stretch=Stretch.UniformToFill});
        Children.Add(movie);
        Loaded+=(_,_)=>{
            if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled || player!=null) return;
            player=new MediaPlayer {IsMuted=true,IsLoopingEnabled=true,Source=MediaSource.CreateFromUri(new Uri("ms-appx:///Assets/VeoPrism.mp4"))};
            movie.SetMediaPlayer(player);player.Play();
        };
        Unloaded+=(_,_)=>{movie.SetMediaPlayer(null);player?.Dispose();player=null;};
    }
}
