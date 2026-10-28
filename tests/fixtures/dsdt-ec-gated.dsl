/*
 * Synthetic DSDT used only by tests/test_patch_dsdt.py.
 *
 * Hand-written minimal table reproducing the EC-gated TPD0 layout of a Lenovo
 * IdeaPad Flex 3 11ADA05 (BIOS >= FPCN24WW). No firmware dump is committed to
 * this repository; this file exists purely so the patcher can be tested
 * offline, without the hardware.
 */
DefinitionBlock ("", "DSDT", 2, "LENOVO", "CB-01   ", 0x00000002)
{
    Scope (_SB)
    {
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08"))

            Device (LPC0)
            {
                Device (H_EC)
                {
                    Name (TPTY, 0x02)

                    Method (ECRD, 1, NotSerialized)
                    {
                        Return (0x02)
                    }
                }
            }

            Device (I2CD)
            {
                Name (_HID, "INT344B")
            }
        }
    }

    Scope (_SB.PCI0.I2CD)
    {
        Device (TPD0)
        {
            Name (_HID, "MSFT0001")
            Name (SBFG, ResourceTemplate ()
            {
                GpioInt (Level, ActiveLow, ExclusiveAndWake, PullDefault, 0x0000,
                    "\\_SB.GPO0", 0x00, ResourceConsumer, ,
                    )
                    {
                        // Pin list
                        0x0010
                    }
            })

            Method (_CRS, 0, NotSerialized)
            {
                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
                {
                    Name (SBFB, ResourceTemplate ()
                    {
                        I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
                            AddressingMode7Bit, "\\_SB.I2CD",
                            0x00, ResourceConsumer, , Exclusive,
                            )
                    })
                    Return (ConcatenateResTemplate (SBFB, SBFG))
                }

                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
                {
                    Name (SBFC, ResourceTemplate ()
                    {
                        I2cSerialBusV2 (0x002C, ControllerInitiated, 0x00061A80,
                            AddressingMode7Bit, "\\_SB.I2CD",
                            0x00, ResourceConsumer, , Exclusive,
                            )
                    })
                    Return (ConcatenateResTemplate (SBFC, SBFG))
                }
            }

            Method (_DSM, 4, NotSerialized)
            {
                If ((Arg2 == Zero))
                {
                    Return (Buffer (One)
                    {
                         0x03
                    })
                }

                If ((Arg2 == One))
                {
                    Switch (ToInteger (Arg0))
                    {
                        Case (0x01)
                        {
                            If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
                            {
                                Return (0x01)
                            }

                            If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
                            {
                                Return (0x20)
                            }
                        }
                    }
                }

                Return (Zero)
            }
        }
    }
}
