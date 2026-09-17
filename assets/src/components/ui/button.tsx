import * as React from "react"
import { Button as ButtonPrimitive } from "@base-ui/react/button"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const buttonVariants = cva(
  "inline-flex shrink-0 items-center justify-center gap-2 rounded-full border-2 text-sm font-semibold whitespace-nowrap transition-[background-color,border-color,color,box-shadow] outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:pointer-events-none disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default:
          "border-primary bg-primary text-primary-foreground shadow-[0_1px_2px_rgb(0_0_0/0.12)] hover:border-primary/90 hover:bg-primary/90 active:bg-primary/80",
        destructive:
          "border-destructive bg-destructive text-destructive-foreground hover:border-destructive/90 hover:bg-destructive/90 active:bg-destructive/80 focus-visible:ring-destructive/20 dark:focus-visible:ring-destructive/40",
        outline:
          "border-border bg-card text-foreground hover:border-primary hover:bg-accent hover:text-accent-foreground aria-expanded:border-primary aria-expanded:bg-accent aria-expanded:text-accent-foreground",
        secondary: "border-primary bg-card text-primary hover:bg-primary/10",
        ghost:
          "border-transparent bg-transparent hover:bg-accent hover:text-accent-foreground aria-expanded:bg-accent aria-expanded:text-accent-foreground",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default: "h-10 px-5 py-2 has-[>svg]:px-4",
        xs: "h-7 gap-1 border px-2.5 text-xs font-medium has-[>svg]:px-2 [&_svg:not([class*='size-'])]:size-3",
        sm: "h-8 gap-1.5 px-3.5 text-xs has-[>svg]:px-3",
        lg: "h-11 px-6 text-base has-[>svg]:px-5",
        icon: "size-10",
        "icon-xs": "size-7 border [&_svg:not([class*='size-'])]:size-3",
        "icon-sm": "size-8",
        "icon-lg": "size-11",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

function Button({
  asChild = false,
  children,
  className,
  variant = "default",
  size = "default",
  ...props
}: ButtonPrimitive.Props &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
  }) {
  const render = asChild && React.isValidElement(children) ? children : undefined

  return (
    <ButtonPrimitive
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      nativeButton={render ? false : undefined}
      render={render}
      {...props}
    >
      {render ? undefined : children}
    </ButtonPrimitive>
  )
}

export { Button, buttonVariants }
