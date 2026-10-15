/* The dedicated test client keeps all pointer warps inside SDL. */
#ifndef VALIMC_CUA_H
#define VALIMC_CUA_H
static inline CGError ValimcIgnoreWarp(CGPoint point)
{
    (void)point;
    return kCGErrorSuccess;
}
static inline CGError ValimcIgnoreDisplayMove(CGDirectDisplayID display, CGPoint point)
{
    (void)display;
    (void)point;
    return kCGErrorSuccess;
}
static inline CGError ValimcIgnoreAssociation(boolean_t connected)
{
    (void)connected;
    return kCGErrorSuccess;
}
#define CGWarpMouseCursorPosition ValimcIgnoreWarp
#define CGDisplayMoveCursorToPoint ValimcIgnoreDisplayMove
#define CGAssociateMouseAndMouseCursorPosition ValimcIgnoreAssociation
#endif
