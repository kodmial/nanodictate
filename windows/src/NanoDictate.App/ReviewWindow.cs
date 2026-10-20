using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NanoDictate.Core;

namespace NanoDictate.App;

/// <summary>
/// Transient review-before-insert prompt. A dedicated window avoids requiring
/// a visible XamlRoot on the hidden HUD; the worker blocks on its result while
/// the WinUI dispatcher remains free to paint it.
/// </summary>
public sealed class ReviewWindow : Window
{
    private readonly TaskCompletionSource<string> _result =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public ReviewWindow(string transcript)
    {
        Title = "NanoDictate — review transcript";
        AnswerText = "n";

        var text = new TextBlock
        {
            Text = transcript,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Margin = new Thickness(0, 0, 0, 16),
        };
        var insert = new Button
        {
            Content = "Insert",
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(8, 0, 0, 0),
        };
        var discard = new Button
        {
            Content = "Discard",
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        insert.Click += (_, _) => Complete("y");
        discard.Click += (_, _) => Complete("n");

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        buttons.Children.Add(discard);
        buttons.Children.Add(insert);

        var panel = new StackPanel
        {
            Padding = new Thickness(24),
            Spacing = 12,
        };
        panel.Children.Add(new TextBlock
        {
            Text = "Insert this transcript?",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        panel.Children.Add(new ScrollViewer { Content = text, MaxHeight = 280 });
        panel.Children.Add(buttons);
        Content = panel;

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            presenter.IsMaximizable = false;
        }
        AppWindow.Resize(new Windows.Graphics.SizeInt32(520, 360));
        Closed += (_, _) =>
        {
            _result.TrySetResult(AnswerText);
        };
    }

    public string AnswerText { get; private set; }

    public Task<string> Answer => _result.Task;

    private void Complete(string answer)
    {
        AnswerText = answer;
        _result.TrySetResult(answer);
        Close();
    }
}

/// <summary>Dispatcher hop for the controller's review seam.</summary>
public sealed class WindowReviewPrompt : IReviewPrompt
{
    private readonly DispatcherQueue _dispatcher;
    private ReviewWindow? _window;

    public WindowReviewPrompt(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public void Cancel() => _dispatcher.TryEnqueue(() => _window?.Close());

    public string? Ask(string text)
    {
        var answer = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_dispatcher.TryEnqueue(() =>
        {
            if (_window is not null)
            {
                answer.TrySetResult("n");
                return;
            }
            var window = new ReviewWindow(text);
            _window = window;
            window.Closed += (_, _) =>
            {
                _window = null;
                answer.TrySetResult(window.AnswerText);
            };
            window.Activate();
        }))
        {
            return "n";
        }

        if (!answer.Task.Wait(TimeSpan.FromMinutes(2)))
        {
            _dispatcher.TryEnqueue(() => _window?.Close());
            return "n";
        }
        return answer.Task.Result;
    }
}
