namespace DotsHarnessCore;

public sealed class RouterException : Exception
{
    public bool Pending { get; }
    public RouterException(string message, bool pending = false) : base(message) { Pending = pending; }
}
