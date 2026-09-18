public enum Flag {
    #if DEBUG
    public static let packageSees = "DEBUG"
    #else
    public static let packageSees = "no DEBUG"
    #endif
}
